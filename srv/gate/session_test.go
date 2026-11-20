package gate

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"

	"tando/srv/internal/run"
)

// fakeProc makes /proc entries: pid -> (ppid, uids, exe, cmdline, environ).
type fakeProc struct {
	t   *testing.T
	dir string
}

func (f fakeProc) add(pid, ppid int, uids string, exe string, cmdline []string, environ ...string) {
	d := filepath.Join(f.dir, strconv.Itoa(pid))
	write(f.t, filepath.Join(d, "status"), fmt.Sprintf("Name:\tx\nPPid:\t%d\nUid:\t%s\n", ppid, strings.ReplaceAll(uids, " ", "\t")))
	write(f.t, filepath.Join(d, "cmdline"), strings.Join(cmdline, "\x00")+"\x00")
	write(f.t, filepath.Join(d, "environ"), strings.Join(environ, "\x00")+"\x00")
	if exe != "" {
		os.Symlink(exe, filepath.Join(d, "exe"))
	}
}

// the process tree sshd builds for a key's request: sshd (root) -> sshd-session (user) -> the
// gate as login shell (user) -> sudo -> the gate as root (this test process)
func sessionTree(t *testing.T, g *Gate, mutate func(map[string]any)) {
	t.Helper()
	sshd := "/bin/ls" // stands for OpenSSH's binary: any root-owned file
	g.P.SSHD = []string{sshd}
	p := map[string]any{
		"loginExe": g.P.Gate, "loginArgv0": "tando-gate", "loginUIDs": "990 990 990 990",
		"loginCmd": g.P.Gate + " key 0123456789ab", "sessExe": sshd, "sessUIDs": "990 990 990 990",
		"privUIDs": "0 0 0 0", "sudoUIDs": "990 0 0 0", "env": "SSH_ORIGINAL_COMMAND=rsync --server -ltpr . x",
	}
	if mutate != nil {
		mutate(p)
	}
	f := fakeProc{t, g.Env.Proc}
	me := os.Getpid()
	f.add(100, 1, p["privUIDs"].(string), sshd, []string{"sshd"})
	f.add(200, 100, p["sessUIDs"].(string), p["sessExe"].(string), []string{"sshd-session"})
	f.add(300, 200, p["loginUIDs"].(string), p["loginExe"].(string), []string{p["loginArgv0"].(string), dashC, p["loginCmd"].(string)},
		"PATH=/x", "SSH_ORIGINAL_COMMAND=first", p["env"].(string))
	f.add(400, 300, p["sudoUIDs"].(string), "/usr/bin/sudo", []string{"sudo", "-n"})
	f.add(me, 400, "0 0 0 0", g.P.Gate, []string{"tando-gate", "root", "alpha", "begin"})
}

func TestBindSession(t *testing.T) {
	g, _ := testGate(t)
	sessionTree(t, g, nil)
	s, err := g.BindSession(990)
	if err != nil || s.KeyID != "0123456789ab" || s.Request != "rsync --server -ltpr . x" {
		t.Fatalf("%+v %v", s, err)
	}
	refused := map[string]func(map[string]any){
		"login is bash running the script":   func(p map[string]any) { p["loginExe"] = "/usr/bin/bash" },
		"login is another program":           func(p map[string]any) { p["loginExe"] = "/usr/bin/python3" },
		"login argv0 is not the gate":        func(p map[string]any) { p["loginArgv0"] = "python3" },
		"login command is not a forced key":  func(p map[string]any) { p["loginCmd"] = "id" },
		"login command names another key id": func(p map[string]any) { p["loginCmd"] = g.P.Gate + " key 0123456789AB" },
		"login process changed uid":          func(p map[string]any) { p["loginUIDs"] = "990 990 990 0" },
		"login of another user":              func(p map[string]any) { p["loginUIDs"] = "991 991 991 991" },
		"parent is not sshd":                 func(p map[string]any) { p["sessExe"] = "/usr/bin/sleep" },
		"parent is root's":                   func(p map[string]any) { p["sessUIDs"] = "0 0 0 0" },
		"grandparent is not root":            func(p map[string]any) { p["privUIDs"] = "990 990 990 990" },
		"sudo's uids are odd":                func(p map[string]any) { p["sudoUIDs"] = "990 990 0 0" },
	}
	for name, m := range refused {
		t.Run(name, func(t *testing.T) {
			g, _ := testGate(t)
			sessionTree(t, g, m)
			if s, err := g.BindSession(990); err == nil || err.Error() != msgSession {
				t.Fatalf("bound: %+v %v", s, err)
			}
		})
	}
	// called as another deploy user (uid 991): the login process is not wholly 991's
	if _, err := g.BindSession(991); err == nil {
		t.Fatal("bound for another uid")
	}
}

// fakeRun records every argv and answers with out.
type fakeRun struct {
	mu    sync.Mutex
	calls [][]string
	envs  [][]string
	stdin []string
	out   func(argv []string) ([]byte, error)
}

func (f *fakeRun) Output(_ context.Context, c run.Cmd) ([]byte, error) {
	f.mu.Lock()
	f.calls = append(f.calls, c.Argv)
	f.envs = append(f.envs, c.Env)
	in := ""
	if c.Stdin != nil {
		if r, ok := c.Stdin.(*strings.Reader); ok {
			b := make([]byte, r.Len())
			r.Read(b)
			in = string(b)
		}
	}
	f.stdin = append(f.stdin, in)
	f.mu.Unlock()
	if f.out != nil {
		return f.out(c.Argv)
	}
	return nil, nil
}

// deployGate: a gate whose caller is alpha's deploy user (uid 990) running key 0123456789ab.
func deployGate(t *testing.T, cmd string) (*Gate, *fakeRun) {
	g, dir := testGate(t)
	write(t, g.P.Passwd, "tando-d-alpha:x:990:990::"+g.P.CI+"/alpha:"+g.P.Gate+"\n")
	write(t, filepath.Join(g.appDir("alpha"), "app.conf"), "recipe=node\n")
	f := &fakeRun{}
	g.Env.Run = f
	g.Caller = Caller{SSHCommand: cmd, UID: 990, EUID: 990}
	null, _ := os.Open(os.DevNull)
	t.Cleanup(func() { null.Close() })
	g.Stdin = null
	o, _ := os.Create(filepath.Join(dir, "stdout"))
	g.Stdout, g.Stderr = o, o
	return g, f
}

func TestKeyModeArgv(t *testing.T) {
	tests := []struct {
		cmd   string // AGENT, INC: the paths under the test's root
		argv  string // the first command run (sudo or the agent)
		stdin string
	}{
		{"sudo -n AGENT begin alpha anything@host", "sudo -n -- GATE root alpha begin", ""},
		{"sudo -n AGENT end alpha " + tTok, "sudo -n -- GATE root alpha end", "token=" + tTok + "\n"},
		{"sudo -n AGENT activate alpha " + tTok + " 1.5 2", "sudo -n -- GATE root alpha activate", "token=" + tTok + "\nbuild=1.5\nupload=2\n"},
		{"rsync --server -ltprcze.iLsfxCIvu --delete . INC/", "sudo -n -- GATE root alpha receive", ""},
		{"AGENT deploy-status alpha 20261113-170102", "AGENT deploy-status alpha 20261113-170102", ""},
		{"AGENT history alpha 5", "AGENT history alpha 5", ""},
		{"AGENT history alpha", "AGENT history alpha 20", ""},
		{"AGENT status alpha", "AGENT status alpha", ""},
		{"AGENT releases alpha", "AGENT releases alpha", ""},
	}
	for _, tt := range tests {
		t.Run(tt.cmd, func(t *testing.T) {
			g, f := deployGate(t, "")
			r := strings.NewReplacer("GATE", g.P.Gate, "AGENT", g.P.Agent, "INC", g.incoming("alpha"))
			g.Caller.SSHCommand = r.Replace(tt.cmd)
			if err := g.Key([]string{dashC, g.P.Gate + " key 0123456789ab"}); err != nil {
				t.Fatalf("refused: %v", err)
			}
			if len(f.calls) == 0 {
				t.Fatal("nothing ran")
			}
			got, want := strings.Join(f.calls[0], " "), r.Replace(tt.argv)
			if got != want || f.stdin[0] != tt.stdin {
				t.Fatalf("ran %q with stdin %q, want %q with %q", got, f.stdin[0], want, tt.stdin)
			}
		})
	}
	// refused before anything runs (but the refusal is logged once the key is known)
	for _, c := range []string{"", "id", "AGENT status bravo", "AGENT env-ls alpha", "sudo -n AGENT begin alpha;id"} {
		g, f := deployGate(t, "")
		g.Caller.SSHCommand = strings.NewReplacer("AGENT", g.P.Agent).Replace(c)
		if err := g.Key([]string{dashC, g.P.Gate + " key 0123456789ab"}); err == nil {
			t.Errorf("%q: accepted", c)
		}
		if len(f.calls) != 1 || f.calls[0][0] != "logger" || !strings.Contains(f.calls[0][len(f.calls[0])-1], "tando-d-alpha key 0123456789ab refused: ") {
			t.Errorf("%q: ran %q", c, f.calls)
		}
	}
	// not the deploy user: refused, nothing logged
	g, f := deployGate(t, "")
	g.Caller.UID, g.Caller.EUID = 991, 991
	if err := g.Key([]string{dashC, g.P.Gate + " key 0123456789ab"}); err == nil || len(f.calls) != 0 {
		t.Errorf("another uid: %v %q", err, f.calls)
	}
	g.Caller.UID, g.Caller.EUID = 0, 0
	if err := g.Key([]string{dashC, g.P.Gate + " key 0123456789ab"}); err == nil || err.Error() != "key mode never runs as root" {
		t.Errorf("root: %v", err)
	}
}

// An app named rx-alpha has the receivers' old fixed name tando-rx-alpha.service as its own
// service: alpha's uploads neither wait for it nor stop it.
func TestRxOldNameOfAnotherApp(t *testing.T) {
	g, f := deployGate(t, "")
	write(t, filepath.Join(g.appDir("rx-alpha"), "app.conf"), "recipe=node\n")
	f.out = func(argv []string) ([]byte, error) {
		if argv[1] != "list-units" {
			return nil, nil
		}
		return []byte("tando-rx-alpha.service loaded active running x\n"), nil
	}
	if err := g.rxFree("alpha"); err != nil {
		t.Fatalf("app rx-alpha's service counted as an upload of alpha: %v", err)
	}
	f.calls = nil
	g.stopRx("alpha")
	for _, c := range f.calls {
		if slices.Contains(c, "tando-rx-alpha.service") {
			t.Fatalf("stopRx names app rx-alpha's service: %v", c)
		}
	}
	if len(f.calls) == 0 || !slices.Contains(f.calls[0], "tando-rx-alpha@*.service") {
		t.Fatalf("stopRx: %v", f.calls)
	}
}

// rxFree refuses while a receiver of the app runs, waits for one being stopped, resets failed
// ones, ignores ended ones (every receiver has a name of its own) and other apps' units, and
// never asks for a unit by name (that loads it).
func TestRxFree(t *testing.T) {
	states := []string{
		"tando-rx-alpha@aa.service loaded deactivating stop-sigterm x\ntando-rx-alpha@bb.service loaded inactive dead x\n",
		"tando-rx-alpha@aa.service loaded failed failed x\ntando-rx-alpha-2@cc.service loaded active running x\n",
		"tando-rx-alpha@bb.service loaded inactive dead x\ntando-rx-alpha.service loaded inactive dead x\n"}
	g, f := deployGate(t, "")
	i := 0
	f.out = func(argv []string) ([]byte, error) {
		if argv[1] != "list-units" {
			return nil, nil
		}
		s := states[min(i, len(states)-1)]
		i++
		return []byte(s), nil
	}
	if err := g.rxFree("alpha"); err != nil {
		t.Fatal(err)
	}
	ran := ""
	for _, c := range f.calls {
		ran += strings.Join(c, " ") + ";"
	}
	if i != 2 || !strings.Contains(ran, "systemctl reset-failed -- tando-rx-alpha@aa.service;") ||
		!strings.Contains(ran, "list-units --all --plain --no-legend --full -- tando-rx-alpha.service tando-rx-alpha@*.service;") ||
		strings.Contains(ran, " show ") || strings.Contains(ran, "is-active") {
		t.Errorf("%d list calls; ran %s", i, ran)
	}
	for _, a := range []string{"active", "activating", "reloading"} {
		for _, n := range []string{"tando-rx-alpha@dd.service", "tando-rx-alpha.service"} {
			g, f := deployGate(t, "")
			f.out = func([]string) ([]byte, error) { return []byte(n + " loaded " + a + " running x\n"), nil }
			if err := g.rxFree("alpha"); err == nil || err.Error() != "rsync: another upload of alpha is running" {
				t.Errorf("%s %s: %v", n, a, err)
			}
		}
	}
}

// The read verbs pass only this app's rows and the whitelisted deploy-status keys (no log=
// lines: they can carry customer data), with control characters cleaned; info reports the CPU.
func TestReadVerbsFilter(t *testing.T) {
	agentOut := map[string]string{
		"deploy-status": "id=1\nphase=done\nlog=CUSTOMER DATA\nresult=ok\nmessage=a\x1b[31mb\nsecret=x\n",
		"status":        "host\th\napp\talpha\t1\napp\tbravo\t2\nrel\tr1\nhist\tbravo\tx\nhist\talpha\ty\nother\tz\n",
		"history":       "hist\talpha\t1\nhist\tbravo\t2\n",
		"releases":      "rel\t1\t\tv\nx\t2\n",
	}
	want := map[string]string{
		"deploy-status": "id=1\nphase=done\nresult=ok\nmessage=a?[31mb\n",
		"status":        "host\th\napp\talpha\t1\nrel\tr1\nhist\talpha\ty\n",
		"history":       "hist\talpha\t1\n",
		"releases":      "rel\t1\t\tv\n",
	}
	for verb, args := range map[string]string{"deploy-status": " 20261113-170102", "status": "", "history": "", "releases": ""} {
		g, f := deployGate(t, "")
		f.out = func(argv []string) ([]byte, error) { return []byte(agentOut[argv[1]]), nil }
		g.Caller.SSHCommand = g.P.Agent + " " + verb + " alpha" + args
		if err := g.Key([]string{dashC, g.P.Gate + " key 0123456789ab"}); err != nil {
			t.Fatal(err)
		}
		g.Stdout.Seek(0, 0)
		b := make([]byte, 4096)
		n, _ := g.Stdout.Read(b)
		if string(b[:n]) != want[verb] {
			t.Errorf("%s: %q, want %q", verb, b[:n], want[verb])
		}
	}
	g, f := deployGate(t, "")
	f.out = func(argv []string) ([]byte, error) { return []byte("aarch64\n"), nil }
	g.Caller.SSHCommand = g.P.Agent + " info"
	g.Key([]string{dashC, g.P.Gate + " key 0123456789ab"})
	g.Stdout.Seek(0, 0)
	b := make([]byte, 100)
	n, _ := g.Stdout.Read(b)
	if string(b[:n]) != "arch=aarch64\nlibc=glibc\n" {
		t.Errorf("info %q", b[:n])
	}
	// the agent fails: its status is ours, at most 2000 bytes of its stderr pass
	c := &capped{w: discard{}, left: 3}
	if n, _ := c.Write([]byte("abcdef")); n != 6 || c.left != 0 {
		t.Error("capped")
	}
}

// end and activate without a token word read it from stdin (a pipe here, as from sshd).
func TestKeyModeTokenOnStdin(t *testing.T) {
	for in, want := range map[string]string{tTok + "\n": "token=" + tTok + "\n", tTok: "", "bad\n": ""} {
		g, f := deployGate(t, "")
		r, w, _ := os.Pipe()
		w.WriteString(in)
		w.Close()
		g.Stdin = r
		g.Caller.SSHCommand = "sudo -n " + g.P.Agent + " end alpha"
		err := g.Key([]string{dashC, g.P.Gate + " key 0123456789ab"})
		r.Close()
		if want == "" {
			if err == nil || err.Error() != "bad request" {
				t.Errorf("%q: %v", in, err)
			}
			continue
		}
		if err != nil || len(f.stdin) == 0 || f.stdin[0] != want {
			t.Errorf("%q: %v %q", in, err, f.stdin)
		}
	}
}
