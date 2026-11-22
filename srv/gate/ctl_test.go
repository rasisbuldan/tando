package gate

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"tando/srv/internal/out"
)

const testCA = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"

func TestParseCtlCommand(t *testing.T) {
	gate := "/opt/tando/bin/tando-gate"
	good := map[string]CtlIdent{
		gate + " ctl write 5 cp-2026.1":     {Mode: "write", Serial: "5", KeyID: "cp-2026.1"},
		gate + " ctl read - -":              {Mode: "read", Serial: "-", KeyID: "-"},
		gate + " ctl app:shop 77 deploy@cp": {Mode: "app", App: "shop", Serial: "77", KeyID: "deploy@cp"},
	}
	for c, want := range good {
		if id, ok := ParseCtlCommand(c, gate); !ok || id != want {
			t.Errorf("%q: %+v %v", c, id, ok)
		}
	}
	for _, c := range []string{
		gate + " ctl admin 5 x", gate + " ctl app:Shop 5 x", gate + " ctl app: 5 x", gate + " ctl write 5",
		gate + " ctl write 5 x y", gate + " ctl write five x", gate + " ctl write 5 a;b", "/tmp/gate ctl write 5 x",
		gate + " key 0123456789ab", gate + " ctl  write 5 x",
	} {
		if id, ok := ParseCtlCommand(c, gate); ok {
			t.Errorf("accepted %q: %+v", c, id)
		}
	}
}

// sshd's principals: write first, then one line per app, then read; each a forced command with
// the certificate's serial and key id (an unprintable key id becomes "-")
func TestCtlPrincipals(t *testing.T) {
	g, _ := testGate(t)
	for _, d := range []string{"apps/shop", "apps/blog-2", "apps/.hidden", "apps/Bad"} {
		os.MkdirAll(filepath.Join(g.P.Root, d), 0o755)
	}
	write(t, filepath.Join(g.P.Root, "apps", "file"), "")
	got := stdoutOf(t, g, func() error { return g.CtlPrincipals([]string{"42", "cp key\"x"}) })
	gp := g.P.Gate
	want := `restrict,command="` + gp + ` ctl write 42 -" tando-ctl-write
restrict,command="` + gp + ` ctl app:blog-2 42 -" tando-app-blog-2
restrict,command="` + gp + ` ctl app:shop 42 -" tando-app-shop
restrict,command="` + gp + ` ctl read 42 -" tando-ctl-read
`
	if got != want {
		t.Errorf("got\n%s\nwant\n%s", got, want)
	}
	for _, l := range strings.Split(strings.TrimSpace(got), "\n") {
		cmd := strings.TrimSuffix(strings.TrimPrefix(l, `restrict,command="`), l[strings.LastIndex(l, `"`):])
		if _, ok := ParseCtlCommand(cmd, gp); !ok {
			t.Errorf("root mode would refuse its own line %q", cmd)
		}
	}
}

// stdoutOf runs f with g.Stdout a temporary file and returns what it wrote.
func stdoutOf(t *testing.T, g *Gate, f func() error) string {
	t.Helper()
	fh, err := os.CreateTemp(t.TempDir(), "out")
	if err != nil {
		t.Fatal(err)
	}
	defer fh.Close()
	g.Stdout = fh
	if err := f(); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(fh.Name())
	return string(data)
}

func TestParseCAKey(t *testing.T) {
	if k, ok := ParseCAKey(testCA + " ca@control-plane\n"); !ok || k != testCA {
		t.Errorf("%q %v", k, ok)
	}
	for _, l := range []string{
		"", "ssh-ed25519", "ssh-dss AAAAB3NzaC1kc3MAAACBAP", strings.Replace(testCA, "ssh-ed25519", "ssh-rsa", 1),
		"ssh-ed25519 !!!!", "ssh-ed25519 AAAA", testCA[:40],
	} {
		if k, ok := ParseCAKey(l); ok {
			t.Errorf("accepted %q -> %q", l, k)
		}
	}
}

// ctlTree: the session of a ctl login (uid 995 is tando-ctl), with this test process as root mode
func ctlTree(t *testing.T, g *Gate, loginCmd string, loginUIDs string) {
	sessionTree(t, g, func(p map[string]any) {
		p["loginCmd"], p["loginUIDs"], p["sessUIDs"], p["sudoUIDs"] = loginCmd, loginUIDs, "995 995 995 995", "995 0 0 0"
		p["env"] = "X=1"
	})
}

func ctlGate(t *testing.T) *Gate {
	g, _ := testGate(t)
	write(t, g.P.Passwd, "root:x:0:0::/root:/bin/bash\ntando-ctl:x:995:995::"+filepath.Join(g.P.Root, "ctl")+":"+g.P.Gate+
		"\ntando-d-alpha:x:990:990::"+filepath.Join(g.P.CI, "alpha")+":"+g.P.Gate+"\n")
	write(t, filepath.Join(g.P.Root, "ctl", "ca.pub"), testCA+"\n")
	write(t, filepath.Join(g.appDir("alpha"), "app.conf"), "port=4100\n")
	in := filepath.Join(t.TempDir(), "in")
	write(t, in, `{"v":1,"verb":"inventory"}`)
	f, err := os.Open(in)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.Close() })
	g.Stdin = f
	g.Caller = Caller{UID: 995, EUID: 0, SudoUID: "995", SudoUser: "tando-ctl"}
	return g
}

func TestCtlRoot(t *testing.T) {
	g := ctlGate(t)
	ctlTree(t, g, g.P.Gate+" ctl app:alpha 9 cp-1", "995 995 995 995")
	id, in, err := g.CtlRoot(nil)
	if err != nil || id != (CtlIdent{Mode: "app", App: "alpha", Serial: "9", KeyID: "cp-1"}) || string(in) != `{"v":1,"verb":"inventory"}` {
		t.Fatalf("%+v %q %v", id, in, err)
	}
	refused := map[string]func(g *Gate){
		// a deploy key's session cannot reach ctl root mode, and the ctl login cannot claim another mode
		"a deploy key's forced command": func(g *Gate) { ctlTree(t, g, g.P.Gate+" key 0123456789ab", "995 995 995 995") },
		"a forged mode":                 func(g *Gate) { ctlTree(t, g, g.P.Gate+" ctl root 9 x", "995 995 995 995") },
		"sudo from a deploy user":       func(g *Gate) { ctlTree(t, g, g.P.Gate+" ctl write 9 x", "995 995 995 995"); g.Caller.SudoUID = "990" },
		"not through sudo":              func(g *Gate) { ctlTree(t, g, g.P.Gate+" ctl write 9 x", "995 995 995 995"); g.Caller.EUID = 995 },
		"login of another uid":          func(g *Gate) { ctlTree(t, g, g.P.Gate+" ctl write 9 x", "990 990 990 990") },
		"control plane mode off": func(g *Gate) {
			ctlTree(t, g, g.P.Gate+" ctl write 9 x", "995 995 995 995")
			os.Remove(filepath.Join(g.P.Root, "ctl", "ca.pub"))
		},
		"tando-ctl not made by the gate": func(g *Gate) {
			ctlTree(t, g, g.P.Gate+" ctl write 9 x", "995 995 995 995")
			write(t, g.P.Passwd, "tando-ctl:x:995:995::/home/x:/bin/bash\n")
		},
	}
	for name, m := range refused {
		t.Run(name, func(t *testing.T) {
			g := ctlGate(t)
			m(g)
			if id, _, err := g.CtlRoot(nil); err == nil {
				t.Fatalf("bound: %+v", id)
			}
		})
	}
}

// ctl mode (the login) refuses anything that is not the ctl user, and a command on the ssh line
func TestCtlLogin(t *testing.T) {
	g := ctlGate(t)
	fr := &fakeRun{}
	g.Env.Run = fr
	args := []string{dashC, g.P.Gate + " ctl write 9 x"}
	g.Caller = Caller{UID: 995, EUID: 995}
	if err := g.Ctl(args); err != nil || len(fr.calls) != 1 || strings.Join(fr.calls[0], " ") != "sudo -n -- "+g.P.Gate+" ctl-root" {
		t.Fatalf("%v %q", err, fr.calls)
	}
	for name, c := range map[string]Caller{
		"root":          {UID: 0, EUID: 0},
		"a deploy user": {UID: 990, EUID: 990},
		"a command":     {UID: 995, EUID: 995, SSHCommand: "date"},
	} {
		fr.calls = nil
		g.Caller = c
		if err := g.Ctl(args); err == nil || len(fr.calls) != 0 {
			t.Errorf("%s: %v %q", name, err, fr.calls)
		}
	}
	if !IsCtlLogin(args, g.P.Gate) || IsCtlLogin([]string{dashC, g.P.Gate + " key 0123456789ab"}, g.P.Gate) {
		t.Error("IsCtlLogin")
	}
}

func TestCtlAdminBadCA(t *testing.T) {
	g := ctlGate(t)
	in := filepath.Join(t.TempDir(), "ca")
	write(t, in, "not a key\n")
	f, _ := os.Open(in)
	defer f.Close()
	g.Stdin = f
	var b bytes.Buffer
	if err := g.CtlAdmin(out.New(&b), "ctl-setup"); err == nil || !strings.Contains(err.Error(), "not an OpenSSH public key") {
		t.Errorf("%v", err)
	}
}

// the settings sshd -T reports for tando-ctl must be the drop-in's; a global setting that wins
// (another way in) is named
func TestCtlEffective(t *testing.T) {
	gate, dir := "/opt/tando/bin/tando-gate", "/opt/tando/ctl"
	good := "port 22\nauthorizedkeysfile none\nauthorizedkeyscommand none\ntrustedusercakeys /opt/tando/ctl/ca.pub\n" +
		"revokedkeys /opt/tando/ctl/revoked.krl\nauthorizedprincipalscommand /opt/tando/bin/tando-gate ctl-principals %s %i\n" +
		"passwordauthentication no\npermittty no\n"
	if why := ctlEffective([]byte(good), gate, dir); why != "" {
		t.Errorf("good: %s", why)
	}
	bad := strings.Replace(good, "authorizedkeyscommand none", "authorizedkeyscommand /usr/bin/fetch-keys %u", 1)
	if why := ctlEffective([]byte(bad), gate, dir); why != "authorizedkeyscommand /usr/bin/fetch-keys %u" {
		t.Errorf("a global keys command: %q", why)
	}
	if why := ctlEffective([]byte("port 22\n"), gate, dir); why == "" {
		t.Error("nothing applied, but accepted")
	}
}
