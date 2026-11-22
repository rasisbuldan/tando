package gate

import (
	"bytes"
	"embed"
	"encoding/base64"
	"os"
	"path/filepath"
	"strconv"
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

// (a ctl login, the test process as its root mode)
// the test runs as the ctl user (the SSH_USER_AUTH file must be the login's own)
//
//go:embed testdata/ctl/*.pub
var ctlFixtures embed.FS

func fixture(t *testing.T, name string) []byte {
	b, err := ctlFixtures.ReadFile("testdata/ctl/" + name)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// (as root, in the Linux test container, the ctl user is 995 and the auth file is chowned to it)
func ctlUID() int {
	if os.Getuid() == 0 {
		return 995
	}
	return os.Getuid()
}

var (
	cuid  = ctlUID()
	cu    = strconv.Itoa(cuid)
	cuids = cu + " " + cu + " " + cu + " " + cu
)

// ctlTree: the session of a ctl login whose sshd authenticated it with the fixture certificate
// cert (testdata/ctl/<cert>-cert.pub; "" : no SSH_USER_AUTH), this test process as root mode
func ctlTree(t *testing.T, g *Gate, loginCmd string, loginUIDs string, cert ...string) {
	c := "app"
	if len(cert) > 0 {
		c = cert[0]
	}
	env := "X=1"
	if c != "" {
		g.P.AuthTmp = t.TempDir()
		auth := filepath.Join(g.P.AuthTmp, "sshauth.abc123")
		f := strings.Fields(string(fixture(t, c+"-cert.pub")))
		write(t, auth, "publickey "+f[0]+" "+f[1]+"\n")
		if os.Getuid() == 0 {
			os.Chown(auth, cuid, cuid)
		}
		env = "SSH_USER_AUTH=" + auth
	}
	sessionTree(t, g, func(p map[string]any) {
		p["loginCmd"], p["loginUIDs"], p["sessUIDs"], p["sudoUIDs"] = loginCmd, loginUIDs, cuids, cu+" 0 0 0"
		p["env"] = env
	})
}

func ctlGate(t *testing.T) *Gate {
	g, _ := testGate(t)
	write(t, g.P.Passwd, "root:x:0:0::/root:/bin/bash\ntando-ctl:x:"+cu+":"+cu+"::"+filepath.Join(g.P.Root, "ctl")+":"+g.P.Gate+
		"\ntando-d-alpha:x:990:990::"+filepath.Join(g.P.CI, "alpha")+":"+g.P.Gate+"\n")
	ca := fixture(t, "ca.pub")
	write(t, filepath.Join(g.P.Root, "ctl", "ca.pub"), string(ca))
	write(t, filepath.Join(g.appDir("alpha"), "app.conf"), "port=4100\n")
	in := filepath.Join(t.TempDir(), "in")
	write(t, in, `{"v":1,"verb":"inventory"}`)
	f, err := os.Open(in)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.Close() })
	g.Stdin = f
	g.Caller = Caller{UID: cuid, EUID: 0, SudoUID: cu, SudoUser: "tando-ctl"}
	return g
}

func TestCtlRoot(t *testing.T) {
	g := ctlGate(t)
	ctlTree(t, g, g.P.Gate+" ctl app:alpha 9 cp-1", cuids)
	id, in, err := g.CtlRoot(nil)
	if err != nil || id != (CtlIdent{Mode: "app", App: "alpha", Serial: "9", KeyID: "cp-1"}) || string(in) != `{"v":1,"verb":"inventory"}` {
		t.Fatalf("%+v %q %v", id, in, err)
	}
	refused := map[string]func(g *Gate){
		// a deploy key's session cannot reach ctl root mode, and the ctl login cannot claim another mode
		"a deploy key's forced command": func(g *Gate) { ctlTree(t, g, g.P.Gate+" key 0123456789ab", cuids) },
		"a forged mode":                 func(g *Gate) { ctlTree(t, g, g.P.Gate+" ctl root 9 x", cuids) },
		"sudo from a deploy user":       func(g *Gate) { ctlTree(t, g, g.P.Gate+" ctl write 9 x", cuids); g.Caller.SudoUID = "990" },
		"not through sudo":              func(g *Gate) { ctlTree(t, g, g.P.Gate+" ctl write 9 x", cuids); g.Caller.EUID = 995 },
		"login of another uid":          func(g *Gate) { ctlTree(t, g, g.P.Gate+" ctl write 9 x", "990 990 990 990") },
		"control plane mode off": func(g *Gate) {
			ctlTree(t, g, g.P.Gate+" ctl write 9 x", cuids)
			os.Remove(filepath.Join(g.P.Root, "ctl", "ca.pub"))
		},
		"tando-ctl not made by the gate": func(g *Gate) {
			ctlTree(t, g, g.P.Gate+" ctl write 9 x", cuids)
			write(t, g.P.Passwd, "tando-ctl:x:"+cu+":"+cu+"::/home/x:/bin/bash\n")
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
	g.Caller = Caller{UID: cuid, EUID: cuid}
	if err := g.Ctl(args); err != nil || len(fr.calls) != 1 || strings.Join(fr.calls[0], " ") != "sudo -n -- "+g.P.Gate+" ctl-root" {
		t.Fatalf("%v %q", err, fr.calls)
	}
	for name, c := range map[string]Caller{
		"root":          {UID: 0, EUID: 0},
		"a deploy user": {UID: 990, EUID: 990},
		"a command":     {UID: cuid, EUID: cuid, SSHCommand: "date"},
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
	good := "port 22\nauthenticationmethods publickey\npubkeyauthentication yes\npasswordauthentication no\n" +
		"kbdinteractiveauthentication no\nhostbasedauthentication no\ngssapiauthentication no\n" +
		"authorizedkeysfile none\nauthorizedkeyscommand none\ntrustedusercakeys /opt/tando/ctl/ca.pub\n" +
		"revokedkeys /opt/tando/ctl/revoked.krl\nauthorizedprincipalsfile none\n" +
		"authorizedprincipalscommand /opt/tando/bin/tando-gate ctl-principals %s %i\n" +
		"authorizedprincipalscommanduser tando-keys\nforcecommand none\nexposeauthinfo yes\ndisableforwarding yes\npermittty no\n"
	if why := ctlEffective([]byte(good), gate, dir); why != "" {
		t.Errorf("good: %s", why)
	}
	// every other way in, and a setting that would undo the binding, is named
	for from, to := range map[string]string{
		"authorizedkeyscommand none":                 "authorizedkeyscommand /usr/bin/fetch-keys %u",
		"authenticationmethods publickey":            "authenticationmethods any",
		"gssapiauthentication no":                    "gssapiauthentication yes",
		"kbdinteractiveauthentication no":            "kbdinteractiveauthentication yes",
		"hostbasedauthentication no":                 "hostbasedauthentication yes",
		"forcecommand none":                          "forcecommand /bin/sh",
		"exposeauthinfo yes":                         "exposeauthinfo no",
		"authorizedprincipalsfile none":              "authorizedprincipalsfile /etc/ssh/principals",
		"authorizedprincipalscommanduser tando-keys": "authorizedprincipalscommanduser root",
	} {
		bad := strings.Replace(good, from, to, 1)
		if why := ctlEffective([]byte(bad), gate, dir); why != to {
			t.Errorf("%s: %q", to, why)
		}
	}
	// an sshd without GSSAPI does not print it: fine
	if why := ctlEffective([]byte(strings.Replace(good, "gssapiauthentication no\n", "", 1)), gate, dir); why != "" {
		t.Errorf("no gssapi line: %s", why)
	}
	if why := ctlEffective([]byte("port 22\n"), gate, dir); why == "" {
		t.Error("nothing applied, but accepted")
	}
}

// ctlCheck asks sshd about several connections; one whose Match block differs is refused
func TestCtlCheckConnections(t *testing.T) {
	g := ctlGate(t)
	good := "authenticationmethods publickey\npubkeyauthentication yes\npasswordauthentication no\n" +
		"kbdinteractiveauthentication no\nhostbasedauthentication no\n" +
		"authorizedkeysfile none\nauthorizedkeyscommand none\ntrustedusercakeys " + g.ctlDir() + "/ca.pub\n" +
		"revokedkeys " + g.ctlDir() + "/revoked.krl\nauthorizedprincipalsfile none\n" +
		"authorizedprincipalscommand " + g.P.Gate + " ctl-principals %s %i\n" +
		"authorizedprincipalscommanduser tando-keys\nforcecommand none\nexposeauthinfo yes\ndisableforwarding yes\npermittty no\n"
	var specs []string
	fr := &fakeRun{out: func(a []string) ([]byte, error) {
		if len(a) == 2 {
			return []byte("port 22\nport 2222\n"), nil
		}
		specs = append(specs, a[3])
		if strings.Contains(a[3], "addr=10.11.12.13,") && strings.HasSuffix(a[3], "lport=2222") {
			return []byte(strings.Replace(good, "passwordauthentication no", "passwordauthentication yes", 1)), nil
		}
		return []byte(good), nil
	}}
	g.Env.Run = fr
	err := g.ctlCheck()
	if err == nil || !strings.Contains(err.Error(), "from 10.11.12.13 to port 2222 (passwordauthentication yes)") {
		t.Fatalf("%v %q", err, specs)
	}
}

// F1: the mode on the command line holds only when sshd's record of the login is one certificate
// of this CA with that mode's principal, serial and key id
func TestCtlRootNeedsTheCertificate(t *testing.T) {
	g := ctlGate(t)
	ctlTree(t, g, g.P.Gate+" ctl write 7 cp-w", cuids, "write")
	if id, _, err := g.CtlRoot(nil); err != nil || id.Mode != "write" {
		t.Fatalf("write certificate: %+v %v", id, err)
	}
	refused := map[string]func(g *Gate){
		"another way in (no certificate record) naming write": func(g *Gate) { ctlTree(t, g, g.P.Gate+" ctl write - -", cuids, "") },
		"an app certificate, the command line says write":     func(g *Gate) { ctlTree(t, g, g.P.Gate+" ctl write 9 cp-1", cuids, "app") },
		"a read certificate, the command line says write":     func(g *Gate) { ctlTree(t, g, g.P.Gate+" ctl write 8 cp-r", cuids, "read") },
		"another CA's certificate":                            func(g *Gate) { ctlTree(t, g, g.P.Gate+" ctl app:alpha 9 cp-1", cuids, "other") },
		"an expired certificate":                              func(g *Gate) { ctlTree(t, g, g.P.Gate+" ctl app:alpha 9 cp-1", cuids, "expired") },
		"another serial on the command line":                  func(g *Gate) { ctlTree(t, g, g.P.Gate+" ctl app:alpha 10 cp-1", cuids, "app") },
		"another key id on the command line":                  func(g *Gate) { ctlTree(t, g, g.P.Gate+" ctl app:alpha 9 cp-2", cuids, "app") },
		"two methods (publickey and a password)": func(g *Gate) {
			ctlTree(t, g, g.P.Gate+" ctl app:alpha 9 cp-1", cuids, "app")
			f := filepath.Join(g.P.AuthTmp, "sshauth.abc123")
			b, _ := os.ReadFile(f)
			os.WriteFile(f, append(b, []byte("password\n")...), 0o600)
		},
		"an auth file outside sshd's directory": func(g *Gate) {
			ctlTree(t, g, g.P.Gate+" ctl app:alpha 9 cp-1", cuids, "app")
			g.P.AuthTmp = t.TempDir()
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

func TestParseCert(t *testing.T) {
	pub := fixture(t, "app-cert.pub")
	f := strings.Fields(string(pub))
	blob, _ := base64.StdEncoding.DecodeString(f[1])
	c, ok := ParseCert(blob)
	if !ok || c.Serial != 9 || c.KeyID != "cp-1" || len(c.Principals) != 1 || c.Principals[0] != "tando-app-alpha" ||
		c.ValidBefore != 0xffffffffffffffff || len(c.CAKey) == 0 {
		t.Fatalf("%+v %v", c, ok)
	}
	for i := 0; i < len(blob); i += 7 {
		if _, ok := ParseCert(blob[:i]); ok {
			t.Fatalf("a cut certificate (%d bytes) parsed", i)
		}
	}
}

// F5: an empty list replaces one with entries only when asked by name; a list for another CA
// is refused
func TestCtlKRL(t *testing.T) {
	g := ctlGate(t)
	krl := filepath.Join(g.ctlDir(), "revoked.krl")
	write(t, krl, "KRL-with-entries")
	empty := filepath.Join(t.TempDir(), "empty")
	write(t, empty, "")
	f, _ := os.Open(empty)
	g.Stdin = f
	var b bytes.Buffer
	if err := g.CtlAdmin(out.New(&b), "ctl-krl"); err == nil || !strings.Contains(err.Error(), "ctl_krl=empty") {
		t.Errorf("emptied without asking: %v", err)
	}
	if data, _ := os.ReadFile(krl); string(data) != "KRL-with-entries" {
		t.Error("the list changed")
	}
	f.Seek(0, 0)
	g.krlEmpty = true
	if err := g.CtlAdmin(out.New(&b), "ctl-krl"); err != nil {
		t.Errorf("ctl_krl=empty: %v", err)
	}
	if data, _ := os.ReadFile(krl); len(data) != 0 {
		t.Error("not emptied")
	}
	f.Close()

	listing := "# KRL version 0\n# CA key ssh-ed25519 SHA256:other\nserial: 99\nserial: 100\n"
	if _, why := krlEntries([]byte(listing), []string{"256", "SHA256:ours", "ca"}); why == "" {
		t.Error("a list for another CA was accepted")
	}
	if n, why := krlEntries([]byte(strings.Replace(listing, "SHA256:other", "SHA256:ours", 1)), []string{"256", "SHA256:ours", "ca"}); why != "" || n != 2 {
		t.Errorf("our CA: %d %q", n, why)
	}
	if n, why := krlEntries([]byte("# KRL version 0\nhash: SHA256:abc\n"), []string{"256", "SHA256:ours"}); why != "" || n != 1 {
		t.Errorf("keys only: %d %q", n, why)
	}
}

func TestParseCAKeyRSASize(t *testing.T) {
	if _, ok := ParseCAKey("ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDQ+bei0eMOq4OtS446cTcHjpY0MwVi4PQmTeMuJ/vwVhNQOk9wTetA48oxQTdQlEo76agNi2UDYGIi1yJFM7E1fQplKj5Vmaj4p1lUDgIrET65lJFr3v45OgFLKfkJpc6AGW47RN31HChQdl4bUpWbwvuPxYXyrdZN4O4kea1SKeEISzwda2pS5pUNgYKlpWPERbDoKdKoDGmHeRPyLzTkynyD23ABWWsBjJ5EHSATDSjg0GnIR5+Hj75eE4G09S28xZQ43E4SbTRg7bk8nMQiOGTlUhm/lzTQGa0/RFFRdV2vLOwRGv8JRlihSeZpJbAn1ndV7ky6fZ2V0NWXdTF7"); ok {
		t.Error("a 2048-bit RSA CA was accepted")
	}
	if _, ok := ParseCAKey("ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC+mJa+8gFvcIlhd+fCT+dY8JVb8hAHL5u8RlFS6ffX+hefMd7a9gHRiJ+dEnJpo04G2/WYewaBWAVMQGWja5O5YAva6eg0Pc6RuJ510ZzmqGO3KS9st4x1krKaF239ex3fQb8v4bGDrBmee6GtwBfnhzHMKBEPyEFLaYhoGG76wMOvXpWiNFQRYJzVA5X6KRddmzdBeGtn+tMMKquowF9NUVILN6RBi6axZVARcHww0s8M1p7SM3x02+PuQQxxtk3eyOnGuHQGc7a/oZ8t5z613RhsvIGSJ9L5ijzKHtif5FIwgLxLktCfgZHo5FzUXSznSUbleEMGSuQ+0sqq6My/nOdJZQ0llYfFWr+8LcwjhUT0XY8ezChaTn0w3gLWh884y9K+syN86K1u9JAuqwVYv7KXeXwPMZ1A7LsTklD9pXjRuEt14RehTcNSiwMcc05VCXxgTIacdRzP4YmSlSzvFCl61QtMS+5GhfJV5sTvIw2ZPRC40xMG/Mrt+Nq0Dic="); !ok {
		t.Error("a 3072-bit RSA CA was refused")
	}
}
