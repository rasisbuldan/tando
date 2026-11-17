package gate

import (
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"tando/srv/internal/lock"
)

// A fake host for root mode and admin mode: a temp root, /etc files, a fake /proc with the key's
// ssh session above this test process, a cgroup tree, and a runner that answers systemctl,
// systemd-run, tando-agent, visudo, sshd, useradd, getent... and records every argv. The deploy
// user tando-d-alpha has the test's own uid, so files can be made and owned without root.

const (
	hKey   = "0123456789ab"
	hToken = "11111111-2222-4333-8444-555555555555"
	hRel   = "20261117-010101"
)

type host struct {
	mu   sync.Mutex // answer runs in the receiver's goroutine too
	t    *testing.T
	g    *Gate
	f    *fakeRun
	dir  string
	uid  int
	rxUp bool             // systemd-run was called: the receiver unit is "active"
	tk   string           // the receiver's ticket when systemd-run was called
	rxu  string           // the unit systemd-run was asked to create
	fail map[string]bool  // commands that fail ("visudo", "visudo1" = the first try only, "agent begin", "sshd")
	unit string           // list-units' answer before systemd-run ("" = not loaded)
	ran  map[string]int   // calls per command word
	pids map[int]struct{} // fake processes of the deploy user; Kill removes them
}

func newHost(t *testing.T) *host {
	t.Helper()
	if os.Getuid() == 0 {
		t.Skip("the fake host runs as a normal user (the deploy user is the test's own uid)")
	}
	g, dir := testGate(t)
	h := &host{t: t, g: g, dir: dir, uid: os.Getuid(), fail: map[string]bool{}, ran: map[string]int{}, pids: map[int]struct{}{}}
	h.f = &fakeRun{out: h.answer}
	g.Env.Run = h.f
	g.Owner, g.Group = os.Getuid(), os.Getgid()
	g.P.Gate = "/bin/ls" // root-owned, 755: what admin install checks
	g.P.SSHD = []string{"/bin/ls"}
	g.P.SSHDDrop = filepath.Join(dir, "etc/ssh/sshd_config.d/50-tando-ci.conf")
	g.P.Sudoers = filepath.Join(dir, "etc/sudoers.d")
	g.P.CronDeny, g.P.AtDeny = filepath.Join(dir, "etc/cron.deny"), filepath.Join(dir, "etc/at.deny")
	g.P.HostKeys = []string{filepath.Join(dir, "etc/ssh/ssh_host_ed25519_key.pub")}
	g.P.Tmp, g.P.RunUser = nil, filepath.Join(dir, "run/user")
	for _, d := range []string{"etc/ssh/sshd_config.d", "etc/sudoers.d", "run/user"} {
		os.MkdirAll(filepath.Join(dir, d), 0o755)
	}
	write(t, g.P.HostKeys[0], "ssh-ed25519 AAAAhostkey root@server\n")
	write(t, g.P.Passwd, fmt.Sprintf("root:x:0:0::/root:/bin/bash\ntando-keys:x:998:%d::/nonexistent:/usr/sbin/nologin\ntando-d-alpha:x:%d:%d::%s/alpha:%s\n",
		os.Getgid(), h.uid, os.Getgid(), g.P.CI, g.P.Gate))
	write(t, g.P.Group, fmt.Sprintf("root:x:0:\ntando-keys:x:%d:\n", os.Getgid()))
	write(t, filepath.Join(g.appDir("alpha"), "app.conf"), "recipe=node\n")
	os.MkdirAll(g.incoming("alpha"), 0o700)
	os.MkdirAll(filepath.Join(g.home("alpha"), ".ssh"), 0o711)
	write(t, filepath.Join(g.home("alpha"), "keys"), keyLine(hKey, tFP, 1700000000, tPub, "admin"))
	g.Kill = func(pid int) { os.RemoveAll(filepath.Join(g.Env.Proc, strconv.Itoa(pid))); delete(h.pids, pid) }
	g.Caller = Caller{EUID: 0, SudoUID: strconv.Itoa(h.uid), SudoUser: "tando-d-alpha"}
	null, _ := os.Open(os.DevNull)
	t.Cleanup(func() { null.Close() })
	g.Stdin = null
	o, _ := os.Create(filepath.Join(dir, "stdout"))
	e, _ := os.Create(filepath.Join(dir, "stderr"))
	g.Stdout, g.Stderr = o, e
	// the session: sshd (root) -> sshd-session (user) -> the gate as login shell -> sudo -> us
	u := fmt.Sprintf("%d %d %d %d", h.uid, h.uid, h.uid, h.uid)
	fp := fakeProc{t, g.Env.Proc}
	fp.add(100, 1, "0 0 0 0", "/bin/ls", []string{"sshd"})
	fp.add(200, 100, u, "/bin/ls", []string{"sshd-session"})
	fp.add(300, 200, u, g.P.Gate, []string{"tando-gate", dashC, g.P.Gate + " key " + hKey},
		"SSH_ORIGINAL_COMMAND=rsync --server -ltprcze.iLsfxCIvu --delete . "+g.incoming("alpha")+"/")
	fp.add(400, 300, fmt.Sprintf("%d 0 0 0", h.uid), "/usr/bin/sudo", []string{"sudo"})
	fp.add(os.Getpid(), 400, "0 0 0 0", g.P.Gate, []string{"tando-gate", "root", "alpha", "x"})
	// another session of the user: its cgroup and a process in it
	for _, s := range []string{"session-1.scope", "session-7.scope"} {
		write(t, filepath.Join(g.Env.Cgroup, "user.slice", "user-"+strconv.Itoa(h.uid)+".slice", s, "cgroup.kill"), "")
	}
	write(t, filepath.Join(g.Env.Proc, strconv.Itoa(os.Getpid()), "cgroup"),
		"0::/user.slice/user-"+strconv.Itoa(h.uid)+".slice/session-1.scope\n")
	return h
}

// stray adds a process of the deploy user outside the session (endSessions must kill it).
func (h *host) stray(pid int) {
	u := fmt.Sprintf("%d %d %d %d", h.uid, h.uid, h.uid, h.uid)
	fakeProc{h.t, h.g.Env.Proc}.add(pid, 1, u, "/usr/bin/sleep", []string{"sleep"})
	write(h.t, filepath.Join(h.g.Env.Proc, strconv.Itoa(pid), "stat"), strconv.Itoa(pid)+" (sleep) S 1")
	h.pids[pid] = struct{}{}
}

func (h *host) lease(who, id string, started int64) {
	write(h.t, filepath.Join(h.g.appDir("alpha"), "upload"), fmt.Sprintf("token=%s\nwho=%s\nid=%s\nstarted=%d\n", hToken, who, id, started))
}

func (h *host) stdin(s string) {
	p := filepath.Join(h.dir, "stdin")
	write(h.t, p, s)
	f, _ := os.Open(p)
	h.t.Cleanup(func() { f.Close() })
	h.g.Stdin = f
}

func (h *host) answer(argv []string) ([]byte, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	w := argv[0]
	if w == h.g.P.Agent {
		w = "agent " + argv[1]
	}
	h.ran[w]++
	if w == "visudo" && h.fail["visudo1"] && h.ran[w] == 1 {
		return nil, errors.New("visudo: bad")
	}
	if h.fail[w] {
		return nil, errors.New(w + ": failed")
	}
	switch w {
	case "agent begin":
		return []byte("token=" + hToken + "\nupload_as=tando-d-alpha\n"), nil
	case "agent activate":
		return []byte("id=" + hRel + "\nother=1\nsame=1\n"), nil
	case "systemd-run":
		h.rxUp = true
		for _, a := range argv {
			if u, ok := strings.CutPrefix(a, "--unit="); ok {
				h.rxu = u + ".service"
			}
		}
		b, _ := os.ReadFile(h.g.ticket("alpha"))
		h.tk = string(b)
	case "systemctl":
		if argv[1] == "list-units" {
			if h.rxUp {
				return []byte(h.rxu + " loaded active running x\n"), nil
			}
			return []byte(h.unit), nil
		}
	case "getent":
		return nil, errors.New("not found")
	case "uname":
		return []byte("aarch64\n"), nil
	case "useradd":
		u, uid := argv[len(argv)-1], strconv.Itoa(h.uid)
		for i, a := range argv {
			if a == "-u" {
				uid = argv[i+1]
			}
		}
		f, _ := os.OpenFile(h.g.P.Passwd, os.O_APPEND|os.O_WRONLY, 0)
		fmt.Fprintf(f, "%s:x:%s:%d::%s/%s:%s\n", u, uid, os.Getgid(), h.g.P.CI, strings.TrimPrefix(u, "tando-d-"), h.g.P.Gate)
		f.Close()
	}
	return nil, nil
}

// argvs are the commands run, with the test's paths as GATE, AGENT, ROOT; logger lines dropped.
func (h *host) argvs() []string {
	h.f.mu.Lock()
	defer h.f.mu.Unlock()
	r := strings.NewReplacer(h.g.P.Agent, "AGENT", h.g.P.Root, "ROOT", h.g.P.Gate, "GATE")
	var s []string
	for _, c := range h.f.calls {
		if c[0] != "logger" {
			s = append(s, r.Replace(strings.Join(c, " ")))
		}
	}
	return s
}

func (h *host) out() string {
	b, _ := os.ReadFile(filepath.Join(h.dir, "stdout"))
	return string(b)
}

func (h *host) logged() string {
	var s []string
	for _, c := range h.f.calls {
		if c[0] == "logger" {
			s = append(s, c[len(c)-1])
		}
	}
	return strings.Join(s, "|")
}

func mode(t *testing.T, p string) os.FileMode {
	fi, err := os.Lstat(p)
	if err != nil {
		t.Fatalf("%s: %v", p, err)
	}
	return fi.Mode().Perm()
}

func wantArgv(t *testing.T, got []string, want ...string) {
	t.Helper()
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("ran:\n  %s\nwant:\n  %s", strings.Join(got, "\n  "), strings.Join(want, "\n  "))
	}
}

const stopRx = "systemctl kill --signal=KILL -- tando-rx-alpha.service tando-rx-alpha@*.service\n" +
	"systemctl stop -- tando-rx-alpha.service tando-rx-alpha@*.service\n" +
	"systemctl reset-failed -- tando-rx-alpha.service tando-rx-alpha@*.service"

// Every refusal of root mode, in the order it checks, before anything runs.
func TestRootRefusals(t *testing.T) {
	tests := []struct {
		name string
		edit func(h *host)
		args []string
		msg  string
	}{
		{"not root", func(h *host) { h.g.Caller.EUID = 1000 }, nil, "root mode runs through sudo"},
		{"no verb", nil, []string{"alpha"}, "bad call"},
		{"an extra argument", nil, []string{"alpha", "begin", "x"}, "bad call"},
		{"bad app", nil, []string{"../alpha", "begin"}, "bad app"},
		{"no SUDO_UID", func(h *host) { h.g.Caller.SudoUID = "" }, nil, "root mode is for deploy users"},
		{"SUDO_UID 0", func(h *host) { h.g.Caller.SudoUID = "0" }, nil, "root mode is for deploy users"},
		{"SUDO_UID not a number", func(h *host) { h.g.Caller.SudoUID = "1e3" }, nil, "root mode is for deploy users"},
		{"another app", nil, []string{"bravo", "begin"}, "the caller is not the deploy user of bravo"},
		{"not from the key's session", func(h *host) {
			os.Remove(filepath.Join(h.g.Env.Proc, "300", "exe"))
			os.Symlink("/usr/bin/bash", filepath.Join(h.g.Env.Proc, "300", "exe"))
		}, nil, msgSession},
		{"revoked key", func(h *host) { write(h.t, filepath.Join(h.g.home("alpha"), "keys"), "") }, nil, "this key is not registered (revoked?)"},
		{"bad verb", nil, []string{"alpha", "rollback"}, "bad verb"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := newHost(t)
			if tt.edit != nil {
				tt.edit(h)
			}
			args := tt.args
			if args == nil {
				args = []string{"alpha", "begin"}
			}
			err := h.g.Root(args)
			if err == nil || err.Error() != tt.msg {
				t.Fatalf("%v, want %q", err, tt.msg)
			}
			if a := h.argvs(); len(a) != 0 {
				t.Fatalf("ran %q", a)
			}
		})
	}
}

func TestRootBegin(t *testing.T) {
	h := newHost(t)
	h.stray(4242)
	if err := h.g.Root([]string{"alpha", "begin"}); err != nil {
		t.Fatal(err)
	}
	wantArgv(t, h.argvs(), "AGENT begin alpha ci-"+hKey, stopRx)
	if h.out() != "token="+hToken+"\n" {
		t.Errorf("stdout %q (only the token passes)", h.out())
	}
	if _, alive := h.pids[4242]; alive {
		t.Error("a stray process of the deploy user survived begin")
	}
	if !strings.Contains(h.logged(), "tando-d-alpha: ended 1 other session(s)") {
		t.Errorf("logged %q", h.logged())
	}
	used := filepath.Join(h.g.home("alpha"), "state", "used-"+hKey)
	if b, _ := os.ReadFile(used); !strings.HasPrefix(string(b), "used=1800000000") || mode(t, used) != 0o600 || mode(t, filepath.Dir(used)) != 0o700 {
		t.Errorf("used file %q %v", b, mode(t, used))
	}
	if env := strings.Join(h.f.envs[0], " "); env != "PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C SUDO_USER=tando-d-alpha SUDO_UID="+strconv.Itoa(h.uid) {
		t.Errorf("agent env %q", env)
	}
	// the agent refuses (another lease): its message is its own, nothing else happens
	h = newHost(t)
	h.fail["agent begin"] = true
	if err := h.g.Root([]string{"alpha", "begin"}); err == nil || ExitCode(err) != 1 {
		t.Fatalf("%v", err)
	}
	wantArgv(t, h.argvs(), "AGENT begin alpha ci-"+hKey)
}

func TestRootEnd(t *testing.T) {
	tests := []struct {
		name, stdin, who, id, msg string
	}{
		{"no token", "", "ci-" + hKey, "", "bad token"},
		{"a stray parameter", "token=" + hToken + "\nkeyid=" + hKey + "\n", "ci-" + hKey, "", "unknown parameter"},
		{"another token", "token=" + tTok + "\n", "ci-" + hKey, "", "end: no upload lease of this key with that token"},
		{"another key's lease", "token=" + hToken + "\n", "ci-0123456789ac", "", "end: no upload lease of this key with that token"},
		{"the admin's lease", "token=" + hToken + "\n", "admin@laptop", "", "end: no upload lease of this key with that token"},
		{"being activated", "token=" + hToken + "\n", "ci-" + hKey, hRel, "end: no upload lease of this key with that token"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := newHost(t)
			h.lease(tt.who, tt.id, 1800000000)
			h.stdin(tt.stdin)
			if err := h.g.Root([]string{"alpha", "end"}); err == nil || err.Error() != tt.msg {
				t.Fatalf("%v, want %q", err, tt.msg)
			}
			// F4: nothing is stopped before the token and the lease are checked
			if a := h.argvs(); len(a) != 0 {
				t.Fatalf("ran %q", a)
			}
			if !strings.Contains(h.logged(), "tando-d-alpha key "+hKey+" refused: "+tt.msg) {
				t.Errorf("not logged: %q", h.logged())
			}
		})
	}
	h := newHost(t)
	h.lease("ci-"+hKey, "", 1800000000)
	h.stdin("token=" + hToken + "\n")
	if err := h.g.Root([]string{"alpha", "end"}); err != nil {
		t.Fatal(err)
	}
	wantArgv(t, h.argvs(), stopRx, "AGENT end alpha "+hToken)
	if h.out() != "ok=1\n" {
		t.Errorf("stdout %q", h.out())
	}
}

func TestRootActivate(t *testing.T) {
	refusals := []struct{ name, stdin, who, id, frozen, msg string }{
		{"bad parameters", "token=" + hToken + "\n", "ci-" + hKey, "", "", "bad parameters"},
		{"another key's lease", "token=" + hToken + "\nbuild=1\nupload=2\n", "ci-0123456789ac", "", "",
			"this upload no longer holds alpha's upload lease (another deploy took it over after this one stopped writing, or it is older than 15 min); nothing was activated: run the deploy again"},
		{"already frozen", "token=" + hToken + "\nbuild=1\nupload=2\n", "ci-" + hKey, "", hToken, "this upload is already being activated"},
	}
	for _, tt := range refusals {
		t.Run(tt.name, func(t *testing.T) {
			h := newHost(t)
			h.lease(tt.who, tt.id, 1800000000)
			if tt.frozen != "" {
				write(t, filepath.Join(h.g.home("alpha"), "frozen"), "token="+tt.frozen+"\n")
			}
			h.stdin(tt.stdin)
			if err := h.g.Root([]string{"alpha", "activate"}); err == nil || err.Error() != tt.msg {
				t.Fatalf("%v, want %q", err, tt.msg)
			}
			if a := h.argvs(); len(a) != 0 {
				t.Fatalf("ran %q", a)
			}
		})
	}
	h := newHost(t)
	h.lease("ci-"+hKey, "", 1800000000)
	h.stdin("token=" + hToken + "\nbuild=1.5\nupload=2\n")
	write(t, filepath.Join(h.g.incoming("alpha"), "server.js"), "x")
	err := h.g.Root([]string{"alpha", "activate"})
	fr := filepath.Join(h.g.home("alpha"), "frozen")
	if b, _ := os.ReadFile(fr); string(b) != "token="+hToken+"\n" || mode(t, fr) != 0o600 {
		t.Errorf("frozen %q %v (written before anything is stopped)", b, mode(t, fr))
	}
	if runtime.GOOS != "linux" { // the scan reads the tree with Linux's *at calls: refused here
		if err == nil || err.Error() != "could not read the upload" {
			t.Fatalf("%v", err)
		}
		wantArgv(t, h.argvs(), stopRx, "AGENT end alpha "+hToken)
		return
	}
	if err != nil {
		t.Fatal(err)
	}
	wantArgv(t, h.argvs(), stopRx, "AGENT activate alpha "+hToken+" 1.5 2")
	if h.out() != "id="+hRel+"\nsame=1\n" {
		t.Errorf("stdout %q", h.out())
	}
}

func TestRootReceive(t *testing.T) {
	tests := []struct {
		name, req, who, id, frozen string
		started                    int64
		unit, msg                  string
	}{
		{"not rsync", "/opt/tando/bin/tando-agent info", "ci-" + hKey, "", "", 1800000000, "", "not allowed with a deploy key"},
		{"a bad option", "rsync --server -ltprz --link-dest=/x . INC/", "ci-" + hKey, "", "", 1800000000, "", "rsync: option not allowed: --link-dest=/x"},
		{"no lease", "", "admin@laptop", "", "", 1800000000, "", "rsync: no upload lease held by this key (tando deploy takes one)"},
		{"activated", "", "ci-" + hKey, hRel, "", 1800000000, "", "rsync: no upload lease held by this key (tando deploy takes one)"},
		{"frozen", "", "ci-" + hKey, "", hToken, 1800000000, "", "rsync: this upload is being activated; it can no longer change"},
		{"expired", "", "ci-" + hKey, "", "", 1800000000 - 896, "", "rsync: the upload lease expired"},
		{"another receiver", "", "ci-" + hKey, "", "", 1800000000, "tando-rx-alpha.service loaded active running x\n", "rsync: another upload of alpha is running"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := newHost(t)
			if tt.req != "" {
				req := strings.ReplaceAll(tt.req, "INC", h.g.incoming("alpha"))
				write(t, filepath.Join(h.g.Env.Proc, "300", "environ"), "SSH_ORIGINAL_COMMAND="+req+"\x00")
			}
			h.lease(tt.who, tt.id, tt.started)
			if tt.frozen != "" {
				write(t, filepath.Join(h.g.home("alpha"), "frozen"), "token="+tt.frozen+"\n")
			}
			h.unit = tt.unit
			err := h.g.Root([]string{"alpha", "receive"})
			if err == nil || !strings.HasPrefix(err.Error(), tt.msg) {
				t.Fatalf("%v, want %q", err, tt.msg)
			}
			for _, a := range h.argvs() {
				if strings.HasPrefix(a, "systemd-run") {
					t.Fatalf("a receiver was started: %s", a)
				}
			}
		})
	}
	// the receiver: exactly this unit, the options of the session's request, the app's paths
	h := newHost(t)
	h.lease("ci-"+hKey, "", 1800000000)
	h.g.Root([]string{"alpha", "receive"})
	var sr string
	for _, a := range h.argvs() {
		if strings.HasPrefix(a, "systemd-run") {
			sr = a
		}
	}
	want := "systemd-run --quiet --pipe --wait --collect --unit=tando-rx-alpha@NONCE -p User=tando-d-alpha -p Group=tando-d-alpha " +
		"-p UMask=0022 -p Environment=LC_ALL=C -p ProtectSystem=strict -p ReadWritePaths=ROOT/apps/alpha/incoming " +
		"-p ProtectHome=yes -p PrivateTmp=yes -p PrivateDevices=yes -p PrivateNetwork=yes -p IPAddressDeny=any " +
		"-p InaccessiblePaths=-/run/user -p NoNewPrivileges=yes -p RestrictSUIDSGID=yes -p CapabilityBoundingSet= " +
		"-p ProtectKernelTunables=yes -p ProtectKernelModules=yes -p ProtectControlGroups=yes -p ProtectProc=invisible " +
		"-p RestrictNamespaces=yes -p LockPersonality=yes -p MemoryMax=512M -p TasksMax=16 -p LimitFSIZE=1073741824 " +
		"-p RuntimeMaxSec=895 -- GATE rx alpha NONCE -ltprcze.iLsfxCIvu --delete"
	// the nonce is the ticket root wrote (root 644) just before
	tk := h.tk
	if !nonceRe.MatchString(strings.TrimSpace(tk)) {
		t.Fatalf("ticket %q", tk)
	}
	if sr != strings.ReplaceAll(want, "NONCE", strings.TrimSpace(tk)) {
		t.Fatalf("systemd-run:\n  %s\nwant:\n  %s", sr, want)
	}
}

func TestRx(t *testing.T) {
	h := newHost(t)
	nonce := strings.Repeat("ab", 16)
	write(t, h.g.ticket("alpha"), nonce+"\n")
	h.g.Caller = Caller{UID: h.uid, EUID: h.uid}
	if err := h.g.Rx([]string{"alpha", nonce}); err == nil || err.Error() != "rx runs inside its unit only" {
		t.Fatal(err)
	}
	h.g.Caller.InvocationID = "x"
	for args, msg := range map[string]string{"bravo " + nonce: "rx: wrong user", "alpha": "rx: wrong user",
		"alpha " + nonce + " -L": "rsync: option not allowed: -L", "alpha " + nonce + " .": "rsync: bad arguments",
		"alpha " + nonce + " --sender": "rsync: option not allowed: --sender",
		// the upload that started it was ended (ticket gone or another one): nothing is written
		"alpha " + strings.Repeat("cd", 16): "rx: this upload was ended or stopped",
		"alpha -ltpr":                       "rx: this upload was ended or stopped"} {
		if err := h.g.Rx(strings.Fields(args)); err == nil || err.Error() != msg {
			t.Errorf("%s: %v, want %q", args, err, msg)
		}
	}
	if a := h.argvs(); len(a) != 0 {
		t.Fatalf("ran %q", a)
	}
	wd, _ := os.Getwd()
	defer os.Chdir(wd)
	if err := h.g.Rx([]string{"alpha", nonce, "-ltprcze.iLsfxCIvu", "--delete"}); err != nil {
		t.Fatal(err)
	}
	wantArgv(t, h.argvs(), "/usr/bin/rsync --server -ltprcze.iLsfxCIvu --delete . ROOT/apps/alpha/incoming/")
	if mode(t, h.g.incoming("alpha")) != 0o700 {
		t.Error("incoming/ not set back to 700")
	}
	// end (here: its closeUpload) removes the ticket: the same receiver started late refuses
	os.Chdir(wd)
	h.f.calls = nil
	if err := h.g.closeUpload("alpha", "ended", hToken); err != nil {
		t.Fatal(err)
	}
	if err := h.g.Rx([]string{"alpha", nonce, "-ltpr"}); err == nil || err.Error() != "rx: this upload was ended or stopped" {
		t.Fatalf("after end: %v", err)
	}
	if a := h.argvs(); len(a) != 0 {
		t.Fatalf("ran %q after end", a)
	}
}

// Admin mode: refusals, install, the sudo rule with and without requiretty, keys added, rotated,
// listed and revoked, and the app removed.
func TestAdminRefusals(t *testing.T) {
	for _, tt := range []struct {
		edit func(*host)
		args []string
		msg  string
	}{
		{func(h *host) { h.g.Caller.EUID = 5 }, []string{"install"}, "admin mode needs root (sudo)"},
		{func(h *host) { h.g.Caller.SudoUser = "tando-d-alpha" }, []string{"install"}, "not for deploy users"},
		{nil, []string{"key-ls", "Alpha"}, "bad app name"},
		{nil, []string{"key-ls"}, "bad app name"},
		{nil, []string{"key-ls", "bravo"}, "no such app: bravo"},
		{nil, []string{"rollback", "alpha"}, "unknown admin verb"},
		{nil, []string{"receive", "alpha", "scp"}, "receive: rsync only"},
	} {
		h := newAdmin(t)
		h.g.Caller.SudoUser = "admin"
		if tt.edit != nil {
			tt.edit(h)
		}
		if err := h.g.Admin(tt.args); err == nil || err.Error() != tt.msg {
			t.Errorf("%v: %v, want %q", tt.args, err, tt.msg)
		}
	}
	h := newAdmin(t)
	h.g.P.Gate = filepath.Join(h.dir, "gate") // not root's
	write(t, h.g.P.Gate, "x")
	if err := h.g.Admin([]string{"install"}); err == nil || !strings.HasSuffix(err.Error(), "must be root-owned, mode 755") {
		t.Errorf("install with a gate that is not root's: %v", err)
	}
}

func TestAdminInstallSSHD(t *testing.T) {
	h := newAdmin(t)
	h.g.Caller.SudoUser = "admin"
	if err := h.g.Admin([]string{"install"}); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(h.g.P.SSHDDrop); string(b) != string(sshdDropIn()) || mode(t, h.g.P.SSHDDrop) != 0o644 {
		t.Errorf("drop-in %v", mode(t, h.g.P.SSHDDrop))
	}
	if h.out() != "ok=1\n" {
		t.Errorf("stdout %q", h.out())
	}
	a := strings.Join(h.argvs(), ";")
	if !strings.Contains(a, "sshd -t;systemctl reload ssh") || strings.Contains(a, "useradd") {
		t.Errorf("ran %s", a)
	}
	// unchanged: not written, sshd not asked again
	h.f.calls = nil
	h.g.Admin([]string{"install"})
	if strings.Contains(strings.Join(h.argvs(), ";"), "sshd -t") {
		t.Error("an unchanged drop-in was installed again")
	}
	// sshd rejects a new one: the old file comes back
	h = newAdmin(t)
	write(t, h.g.P.SSHDDrop, "# the admin's old one\n")
	h.fail["sshd"] = true
	if err := h.g.Admin([]string{"install"}); err == nil || err.Error() != "sshd rejected the tando drop-in" {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(h.g.P.SSHDDrop); string(b) != "# the admin's old one\n" {
		t.Errorf("not restored: %q", b)
	}
	// tando-keys missing: created with exactly this argv
	h = newAdmin(t)
	write(t, h.g.P.Passwd, strings.Replace(string(must(os.ReadFile(h.g.P.Passwd))), "tando-keys:", "other:", 1))
	h.g.installSSHD()
	h.g.install("")
	if !strings.Contains(strings.Join(h.argvs(), ";"), "useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin --comment tando sshd reads CI keys as this user -- tando-keys") {
		t.Errorf("ran %q", h.argvs())
	}
}

func must[T any](v T, err error) T {
	if err != nil {
		panic(err)
	}
	return v
}

func TestAdminKeyAddRotateRevoke(t *testing.T) {
	h := newHost(t)
	h.g.Caller.SudoUser = "admin"
	write(t, filepath.Join(h.g.home("alpha"), "keys"), "")
	h.fail["visudo1"] = true // sudo-rs: the rule with requiretty is refused, the one without taken
	h.stdin(tPub + " tando-ci-alpha\n")
	if err := h.g.Admin([]string{"key-add", "alpha"}); err != nil {
		t.Fatal(err)
	}
	o := h.out()
	id := strings.TrimPrefix(strings.SplitN(o, "\n", 2)[0], "keyid=")
	if !validKeyID(id) || !strings.Contains(o, "\nfingerprint="+tFP+"\nuser=tando-d-alpha\nrevoked=0\nhostkey=ssh-ed25519 AAAAhostkey\n") {
		t.Fatalf("stdout %q", o)
	}
	home := h.g.home("alpha")
	keys := string(must(os.ReadFile(filepath.Join(home, "keys"))))
	if keys != keyLine(id, tFP, 1800000000, tPub, "admin") || mode(t, filepath.Join(home, "keys")) != 0o600 {
		t.Errorf("keys %q", keys)
	}
	ak := filepath.Join(home, ".ssh", "authorized_keys")
	if b := string(must(os.ReadFile(ak))); b != `restrict,command="/bin/ls key `+id+`" `+tPub+" tando-ci-alpha-"+id+"\n" || mode(t, ak) != 0o640 {
		t.Errorf("authorized_keys %q %v", b, mode(t, ak))
	}
	for p, m := range map[string]os.FileMode{home: 0o711, filepath.Join(home, ".ssh"): 0o711, filepath.Join(home, "state"): 0o700, h.g.incoming("alpha"): 0o700, h.g.P.CI: 0o755} {
		if mode(t, p) != m {
			t.Errorf("%s: %v, want %v", p, mode(t, p), m)
		}
	}
	sf := filepath.Join(h.g.P.Sudoers, "tando-d-alpha")
	if b := string(must(os.ReadFile(sf))); b != string(sudoersRule("/bin/ls", "alpha", false)) || mode(t, sf) != 0o440 {
		t.Errorf("sudoers %q %v", b, mode(t, sf))
	}
	if _, err := os.Stat(sf + ".tmp"); err == nil {
		t.Error("candidate left")
	}
	for _, f := range []string{h.g.P.CronDeny, h.g.P.AtDeny} {
		if string(must(os.ReadFile(f))) != "tando-d-alpha\n" {
			t.Errorf("%s", f)
		}
	}
	a := strings.Join(h.argvs(), "\n")
	for _, w := range []string{"visudo -c -q -f ROOT/../etc/sudoers.d/tando-d-alpha.tmp", "getent group -- tando-m-alpha",
		fmt.Sprintf("systemctl mask --quiet -- user@%d.service", h.uid), "loginctl disable-linger -- tando-d-alpha"} {
		w = strings.Replace(w, "ROOT/../etc", filepath.Join(h.dir, "etc"), 1)
		if !strings.Contains(a, w) {
			t.Errorf("did not run %q:\n%s", w, a)
		}
	}
	if strings.Contains(a, "useradd") {
		t.Error("the existing user was created again")
	}
	// the same key again
	h.stdin(tPub + "\n")
	if err := h.g.Admin([]string{"key-add", "alpha"}); err == nil || err.Error() != "this key is already registered" {
		t.Errorf("%v", err)
	}
	// rotate: a new key, the old one revoked, its lease ended, the user evicted
	h.lease("ci-"+id, "", 1800000000)
	h.f.calls = nil
	_, pub2 := otherKey(t)
	h.stdin(pub2 + "\n")
	os.Truncate(filepath.Join(h.dir, "stdout"), 0)
	h.g.Stdout.Seek(0, 0)
	if err := h.g.Admin([]string{"key-add", "alpha", "rotate"}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(h.out(), "revoked=1\n") || strings.Contains(string(must(os.ReadFile(filepath.Join(home, "keys")))), id) {
		t.Errorf("rotate: %q", h.out())
	}
	a = strings.Join(h.argvs(), "\n")
	for _, w := range []string{"AGENT end alpha " + hToken, "loginctl terminate-user -- tando-d-alpha", stopRx,
		"crontab -r -u tando-d-alpha", "atq", "ipcs -m"} {
		if !strings.Contains(a, w) {
			t.Errorf("rotate did not run %q:\n%s", w, a)
		}
	}
	// key-ls, then revoke: bad selector, unknown key, by fingerprint, all
	os.Truncate(filepath.Join(h.dir, "stdout"), 0)
	h.g.Stdout.Seek(0, 0)
	h.g.Admin([]string{"key-ls", "alpha"})
	if l := h.out(); !strings.HasPrefix(l, "key\t") || strings.Count(l, "\n") != 1 || !strings.Contains(l, "\t-\tadmin\n") {
		t.Errorf("key-ls %q", l)
	}
	for sel, msg := range map[string]string{"x": "give a key id, a SHA256: fingerprint or all", "0123456789ff": "no such key: 0123456789ff (tando ci ls)", "": "nothing to revoke"} {
		h.stdin(sel)
		if err := h.g.Admin([]string{"key-revoke", "alpha"}); err == nil || err.Error() != msg {
			t.Errorf("revoke %q: %v", sel, err)
		}
	}
	h.stdin("all\n")
	os.Truncate(filepath.Join(h.dir, "stdout"), 0)
	h.g.Stdout.Seek(0, 0)
	if err := h.g.Admin([]string{"key-revoke", "alpha"}); err != nil || h.out() != "revoked=1\n" {
		t.Fatalf("revoke all: %v %q", err, h.out())
	}
	if b := must(os.ReadFile(ak)); len(b) != 0 {
		t.Errorf("authorized_keys after revoke all: %q", b)
	}
	// remove: rule, user, uid retired, home gone
	h.f.calls = nil
	os.Truncate(filepath.Join(h.dir, "stdout"), 0)
	h.g.Stdout.Seek(0, 0)
	if err := h.g.Admin([]string{"remove", "alpha"}); err != nil || h.out() != "removed=tando-d-alpha\n" {
		t.Fatalf("remove: %v %q", err, h.out())
	}
	if _, err := os.Stat(sf); err == nil {
		t.Error("sudo rule kept")
	}
	if _, err := os.Stat(home); err == nil {
		t.Error("home kept")
	}
	if string(must(os.ReadFile(filepath.Join(h.g.P.Root, "retired-uids")))) != strconv.Itoa(h.uid)+"\n" {
		t.Error("uid not retired")
	}
	if string(must(os.ReadFile(h.g.P.CronDeny))) != "" {
		t.Error("cron.deny kept the user")
	}
	if a := strings.Join(h.argvs(), "\n"); !strings.Contains(a, "userdel -- tando-d-alpha") ||
		!strings.Contains(a, fmt.Sprintf("systemctl unmask --quiet -- user@%d.service", h.uid)) {
		t.Errorf("remove ran:\n%s", a)
	}
}

func otherKey(t *testing.T) (string, string) {
	// a second valid ed25519 public key (any 32 bytes are one for the format check)
	blob := append(append([]byte{0, 0, 0, 11}, "ssh-ed25519"...), 0, 0, 0, 32)
	blob = append(blob, []byte("tando-test-second-key-0123456789")...)
	pub := "ssh-ed25519 " + b64(blob)
	_, fp, err := ParsePublicKey(pub)
	if err != nil {
		t.Fatal(err)
	}
	return fp, pub
}

func TestAdminSudoersRejected(t *testing.T) {
	h := newHost(t)
	h.fail["visudo"] = true
	if err := h.g.writeSudoers("alpha"); err == nil || err.Error() != "visudo rejected the rule" {
		t.Fatal(err)
	}
	if ents, _ := os.ReadDir(h.g.P.Sudoers); len(ents) != 0 {
		t.Errorf("left %v", ents)
	}
	// classic sudo: the first rule (requiretty switched off) is taken
	h = newHost(t)
	if err := h.g.writeSudoers("alpha"); err != nil {
		t.Fatal(err)
	}
	if b := string(must(os.ReadFile(filepath.Join(h.g.P.Sudoers, "tando-d-alpha")))); !strings.Contains(b, "Defaults:tando-d-alpha !requiretty, env_reset, !lecture\n") {
		t.Errorf("%q", b)
	}
}

func TestEnsureUserCreates(t *testing.T) {
	h := newHost(t)
	write(t, filepath.Join(h.g.P.Root, "retired-uids"), "999\n")
	write(t, filepath.Join(h.g.appDir("bravo"), "app.conf"), "recipe=node\n")
	os.MkdirAll(h.g.incoming("bravo"), 0o755)
	h.g.ensureUser("bravo") // (ends at handing incoming/ to uid 998, which a test cannot do)
	a := strings.Join(h.argvs(), "\n")
	want := "useradd --system --user-group --no-create-home --home-dir ROOT/ci/bravo --shell GATE -u 998 --comment tando CI deploys for bravo -- tando-d-bravo\nusermod -p * -- tando-d-bravo"
	if !strings.Contains(a, want) {
		t.Errorf("ran:\n%s\nwant:\n%s", a, want)
	}
	// a user of that name that tando-gate did not make
	h = newHost(t)
	write(t, filepath.Join(h.g.appDir("bravo"), "app.conf"), "recipe=node\n")
	f, _ := os.OpenFile(h.g.P.Passwd, os.O_APPEND|os.O_WRONLY, 0)
	fmt.Fprintf(f, "tando-d-bravo:x:%d:%d::/home/x:/bin/bash\n", 4321, 4321)
	f.Close()
	if err := h.g.ensureUser("bravo"); err == nil || err.Error() != "user tando-d-bravo exists but was not created by tando-gate" {
		t.Errorf("%v", err)
	}
}

func TestAdminReceiveRefusals(t *testing.T) {
	for _, tt := range []struct{ who, msg string }{
		{"ci-" + hKey, "rsync: no upload lease of the admin (tando deploy takes one)"},
		{"", "rsync: no upload lease of the admin (tando deploy takes one)"},
	} {
		h := newAdmin(t)
		h.g.Caller.SudoUser = "admin"
		if tt.who != "" {
			h.lease(tt.who, "", 1800000000)
		}
		err := h.g.Admin([]string{"receive", "alpha", "rsync", "--server", "-ltprz", ".", h.g.incoming("alpha") + "/"})
		if err == nil || err.Error() != tt.msg {
			t.Errorf("%v, want %q", err, tt.msg)
		}
	}
	h := newAdmin(t)
	h.lease("admin@laptop", "", 1800000000)
	write(t, h.g.P.Passwd, strings.Replace(string(must(os.ReadFile(h.g.P.Passwd))), "tando-d-alpha:x:"+strconv.Itoa(h.uid), "tando-d-alpha:x:4321", 1))
	err := h.g.Admin([]string{"receive", "alpha", "rsync", "--server", "-ltprz", ".", h.g.incoming("alpha") + "/"})
	if err == nil || err.Error() != "incoming/ of alpha does not belong to tando-d-alpha" {
		t.Errorf("%v", err)
	}
}

func TestEvictUser(t *testing.T) {
	h := newHost(t)
	h.stray(4243)
	h.f.out = func(argv []string) ([]byte, error) {
		switch strings.Join(argv, " ") {
		case "atq":
			return []byte("5\tMon Nov 17 01:00:00 2026 a tando-d-alpha\n6\tMon Nov 17 01:00:00 2026 a someone\n"), nil
		case "ipcs -m":
			return []byte("key shmid owner perms\n0x0 123 tando-d-alpha 600\n0x0 124 root 600\n0x0 x;y tando-d-alpha 600\n"), nil
		}
		return h.answer(argv)
	}
	h.g.evictUser("alpha")
	a := strings.Join(h.argvs(), "\n")
	for _, w := range []string{"loginctl terminate-user -- tando-d-alpha", fmt.Sprintf("systemctl stop -- user@%d.service", h.uid),
		stopRx, "crontab -r -u tando-d-alpha", "atrm -- 5", "ipcrm -m 123"} {
		if !strings.Contains(a, w) {
			t.Errorf("did not run %q", w)
		}
	}
	for _, w := range []string{"atrm -- 6", "ipcrm -m 124", "x;y"} {
		if strings.Contains(a, w) {
			t.Errorf("ran %q", w)
		}
	}
	if _, alive := h.pids[4243]; alive {
		t.Error("process survived")
	}
}

func b64(b []byte) string { return base64.StdEncoding.EncodeToString(b) }

// newAdmin is the host with the admin's sudo as the caller (admin mode).
func newAdmin(t *testing.T) *host {
	h := newHost(t)
	h.g.Caller.SudoUser = "admin"
	return h
}

// end and activate close the upload under the lease lock before they stop anything: when the
// first stop command runs, the lease is marked ended (frozen), the receiver's ticket is gone, and
// the lock is free again only after that.
func TestCloseBeforeStop(t *testing.T) {
	for _, verb := range []string{"end", "activate"} {
		h := newHost(t)
		h.lease("ci-"+hKey, "", 1800000000)
		write(t, h.g.ticket("alpha"), strings.Repeat("ab", 16)+"\n")
		h.stdin("token=" + hToken + "\nbuild=1\nupload=2\n")
		var seen string
		h.f.out = func(argv []string) ([]byte, error) {
			if seen == "" && argv[0] == "systemctl" && argv[1] == "kill" {
				_, terr := os.Stat(h.g.ticket("alpha"))
				file := map[string]string{"end": "ended", "activate": "frozen"}[verb]
				seen = fmt.Sprintf("ticket gone %v, %s %q", os.IsNotExist(terr), file,
					kv(filepath.Join(h.g.home("alpha"), file), "token"))
			}
			return h.answer(argv)
		}
		h.g.Root([]string{"alpha", verb})
		want := fmt.Sprintf("ticket gone true, %s %q", map[string]string{"end": "ended", "activate": "frozen"}[verb], hToken)
		if seen != want {
			t.Errorf("%s: at the first stop: %s, want %s", verb, seen, want)
		}
	}
	// a receive for a lease that was ended is refused before anything starts
	h := newHost(t)
	h.lease("ci-"+hKey, "", 1800000000)
	write(t, filepath.Join(h.g.home("alpha"), "ended"), "token="+hToken+"\n")
	if err := h.g.Root([]string{"alpha", "receive"}); err == nil || err.Error() != "rsync: this upload was ended; it can no longer change" {
		t.Fatalf("%v", err)
	}
	for _, a := range h.argvs() {
		if strings.HasPrefix(a, "systemd-run") {
			t.Fatal("a receiver was started for an ended lease")
		}
	}
}

// The lease lock is not given back while systemd is still creating the receiver's unit (here:
// "activating" for longer than the 5 s the first version waited), so end cannot slip in between.
func TestReceiveHoldsLockUntilActive(t *testing.T) {
	h := newHost(t)
	h.lease("ci-"+hKey, "", 1800000000)
	lockFile := filepath.Join(h.g.appDir("alpha"), "lease.lock")
	var polls atomic.Int32
	var started, freed atomic.Bool
	h.f.out = func(argv []string) ([]byte, error) {
		switch {
		case argv[0] == "systemd-run":
			started.Store(true)
			// systemd is slow to create the unit (6 s and more); meanwhile the lock stays taken
			for end := time.Now().Add(8 * time.Second); polls.Load() < 60 && time.Now().Before(end); {
				if l, err := lock.Acquire(lockFile, 0); err == nil {
					freed.Store(true)
					l.Release()
				}
				time.Sleep(20 * time.Millisecond)
			}
		case started.Load() && argv[0] == "systemctl" && argv[1] == "list-units":
			polls.Add(1)
			if l, err := lock.Acquire(lockFile, 0); err == nil {
				freed.Store(true)
				l.Release()
			}
			return []byte("tando-rx-alpha.service loaded activating start x\n"), nil
		}
		return h.answer(argv)
	}
	h.g.Root([]string{"alpha", "receive"})
	if polls.Load() < 60 || freed.Load() {
		t.Fatalf("%d polls; lock free while the unit was not active yet: %v", polls.Load(), freed.Load())
	}
}
