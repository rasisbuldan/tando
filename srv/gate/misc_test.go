package gate

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"tando/srv/internal/env"
)

func TestReadParams(t *testing.T) {
	tests := []struct {
		in   string
		want Params
		err  string
	}{
		{"token=" + tTok + "\nbuild=1.5\nupload=0\n", Params{tTok, "1.5", "0"}, ""},
		{"token=" + tTok + "\n\n", Params{Token: tTok}, ""},
		{"token=" + tTok, Params{}, ""}, // no newline: not read (bash)
		{"=x\n", Params{}, ""},
		{"keyid=0123456789ab\n", Params{}, "unknown parameter"},
		{"token=" + tTok + "\ncmd=id\n", Params{}, "unknown parameter"},
		{"token=x\n", Params{}, "bad token"},
		{"token\n", Params{}, "bad token"},
		{"build=1e9\n", Params{}, "bad timing"},
		{"upload=-1\n", Params{}, "bad timing"},
		{strings.Repeat("\n", 9), Params{}, "too many parameters"},
		{"token=" + tTok + strings.Repeat("x", 300) + "\n", Params{}, "bad token"},
		{"tok\x00en=" + tTok + "\n", Params{Token: tTok}, ""},
	}
	for _, tt := range tests {
		got, err := ReadParams(strings.NewReader(tt.in))
		if tt.err != "" {
			if err == nil || err.Error() != tt.err {
				t.Errorf("%q: %v, want %q", tt.in, err, tt.err)
			}
			continue
		}
		if err != nil || got != tt.want {
			t.Errorf("%q: %+v %v, want %+v", tt.in, got, err, tt.want)
		}
	}
}

func TestKV(t *testing.T) {
	d := []byte("a=1\nb=x=\nc=r\r\na=2\nlast=no-newline")
	for k, want := range map[string]string{"a": "1", "b": "x=", "c": "r\r", "last": "", "none": ""} {
		if got := kvOf(d, k); got != want {
			t.Errorf("kv %s = %q, want %q", k, got, want)
		}
	}
}

func testGate(t *testing.T) (*Gate, string) {
	t.Helper()
	dir := t.TempDir()
	p := OSPaths(filepath.Join(dir, "opt"))
	p.Passwd = filepath.Join(dir, "passwd")
	p.Group = filepath.Join(dir, "group")
	e := env.Env{Root: p.Root, Proc: filepath.Join(dir, "proc"), Cgroup: filepath.Join(dir, "cg"),
		Now: func() time.Time { return time.Unix(1800000000, 0) }}
	g := &Gate{Env: e, P: p, Stdin: os.Stdin, Stdout: os.Stdout, Stderr: os.Stderr}
	return g, dir
}

func write(t *testing.T, path, data string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestLimitsAndLease(t *testing.T) {
	g, _ := testGate(t)
	if l := g.limits(); l != (Limits{3072 << 20, 200000, 1024 << 20}) {
		t.Errorf("defaults %+v", l)
	}
	write(t, filepath.Join(g.P.Root, "host.conf"), "ci_max_mb=24\nci_max_files=0300\nci_max_file_mb=8x\nci_max_mb=99\n")
	if l := g.limits(); l != (Limits{24 << 20, 300, 1024 << 20}) {
		t.Errorf("host.conf %+v", l)
	}
	write(t, filepath.Join(g.appDir("alpha"), "upload"), "token="+tTok+"\nwho=ci-0123456789ab\nstarted=1799999900\n")
	if l := g.lease("alpha"); l.Token != tTok || l.Who != "ci-0123456789ab" || l.ID != "" || l.Remain != 900-100-5 {
		t.Errorf("lease %+v", l)
	}
	write(t, filepath.Join(g.appDir("alpha"), "upload"), "token=x\nstarted=x1\n")
	if l := g.lease("alpha"); l.Remain != 900-1800000000-5 {
		t.Errorf("bad started %+v", l)
	}
}

func TestCallerApp(t *testing.T) {
	g, _ := testGate(t)
	write(t, g.P.Passwd, strings.Join([]string{
		"root:x:0:0:root:/root:/bin/bash",
		"tando-d-alpha:x:990:990:tando CI:" + g.P.CI + "/alpha:" + g.P.Gate,
		"tando-d-bravo:x:991:991::" + g.P.CI + "/bravo:/bin/bash",       // another shell
		"tando-d-charlie:x:992:992::/home/charlie:" + g.P.Gate,          // another home
		"tando-d-delta:x:993:993::" + g.P.CI + "/delta:" + g.P.Gate,     // no app.conf
		"tando-d-Echo:x:994:994::" + g.P.CI + "/Echo:" + g.P.Gate,       // not an app name
		"tando-x-foxtrot:x:995:995::" + g.P.CI + "/foxtrot:" + g.P.Gate, // not a deploy user
		"tando-d-alpha:x:996:996::" + g.P.CI + "/alpha:" + g.P.Gate,     // a second alpha: only 990 is it
		"broken:x:+997:997::" + g.P.CI + "/alpha:" + g.P.Gate,
		"",
	}, "\n"))
	for _, a := range []string{"alpha", "bravo", "charlie", "Echo", "foxtrot"} {
		write(t, filepath.Join(g.appDir(a), "app.conf"), "recipe=node\n")
	}
	for uid, want := range map[int]string{990: "alpha", 991: "", 992: "", 993: "", 994: "", 995: "", 0: "", 997: "", 12345: ""} {
		got, ok := g.CallerApp(uid)
		if ok != (want != "") || (ok && got != want) {
			t.Errorf("uid %d: %q %v, want %q", uid, got, ok, want)
		}
	}
	if a, ok := g.CallerApp(996); !ok || a != "alpha" {
		t.Errorf("996 is also shaped like alpha's user: %q %v", a, ok) // sudo's SUDO_UID decides which
	}
}

func TestTakeEnv(t *testing.T) {
	c := TakeEnv([]string{"SSH_ORIGINAL_COMMAND=a b", "SUDO_UID=990", "SUDO_USER=tando-d-alpha", "INVOCATION_ID=x",
		"LD_PRELOAD=/x.so", "PATH=/tmp", "BASH_ENV=/x", "HOME=/x", "SUDO_USER", "GODEBUG=x"}, 990, 0)
	if c.SSHCommand != "a b" || c.SudoUID != "990" || c.SudoUser != "tando-d-alpha" || c.InvocationID != "x" || c.EUID != 0 {
		t.Errorf("%+v", c)
	}
	if c := TakeEnv([]string{"SUDO_USER=a\tb"}, 0, 0); c.SudoUser != "" {
		t.Error("a SUDO_USER with a tab must not be kept")
	}
	if bad := UnsafeRuntimeEnv([]string{"GODEBUG=x", "GOTRACEBACK=all", "GOPATH=/x", "LC_ALL=C"}); strings.Join(bad, ",") != "GODEBUG,GOTRACEBACK" {
		t.Errorf("unsafe %v", bad)
	}
}

// The sshd drop-in and the sudo rule are byte for byte what the shell version wrote: servers it
// set up see no change.
func TestSSHDAndSudoers(t *testing.T) {
	d := string(sshdDropIn())
	for _, l := range []string{"Match User tando-d-*\n", "\tAuthorizedKeysCommand /usr/bin/cat %h/.ssh/authorized_keys\n",
		"\tAuthorizedKeysCommandUser tando-keys\n", "\tSetEnv LC_ALL=C LANG=C\n", "\tMaxSessions 4\n", "\tPermitTTY no\n"} {
		if !strings.Contains(d, l) {
			t.Errorf("drop-in lacks %q", l)
		}
	}
	if strings.Count(d, "\n") != 20 || !strings.HasPrefix(d, "# tando CI deploy users:") {
		t.Errorf("drop-in:\n%s", d)
	}
	want := "# tando CI deploy user for alpha: exact commands, nothing else (managed by tando-gate)\n" +
		"Defaults:tando-d-alpha !requiretty, env_reset, !lecture\n" +
		"tando-d-alpha ALL=(root) NOPASSWD: " + tGate + " root alpha begin, " + tGate + " root alpha end, " +
		tGate + " root alpha activate, " + tGate + " root alpha receive\n"
	if got := string(sudoersRule(tGate, "alpha", true)); got != want {
		t.Errorf("rule:\n%s\nwant:\n%s", got, want)
	}
	if got := string(sudoersRule(tGate, "alpha", false)); got != strings.Replace(want, "!requiretty, ", "", 1) {
		t.Errorf("rule without requiretty:\n%s", got)
	}
}

func TestDenyList(t *testing.T) {
	g, dir := testGate(t)
	f := filepath.Join(dir, "cron.deny")
	write(t, f, "someone")
	if err := g.denyList(f, "tando-d-alpha", true); err != nil {
		t.Fatal(err)
	}
	g.denyList(f, "tando-d-alpha", true)
	if b, _ := os.ReadFile(f); string(b) != "someone\ntando-d-alpha\n" {
		t.Errorf("add: %q", b)
	}
	g.denyList(f, "tando-d-alpha", false)
	if b, _ := os.ReadFile(f); string(b) != "someone\n" {
		t.Errorf("del: %q", b)
	}
	if fi, _ := os.Stat(f); fi.Mode().Perm() != 0o644 {
		t.Errorf("mode %v", fi.Mode())
	}
}
