package gate

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"

	"tando/srv/internal/atomicfile"
	"tando/srv/internal/fsinfo"
	"tando/srv/internal/out"
	"tando/srv/internal/run"
	"tando/srv/internal/valid"
)

// Control plane mode (docs/CONTROL-PLANE.md; the protocol is srv/ctl).
//
// One login user, tando-ctl, whose login shell is this program. sshd admits it only with an
// OpenSSH user certificate signed by the CA in Root/ctl/ca.pub (TrustedUserCAKeys: sshd checks
// the signature, the validity interval, source-address and the revocation list Root/ctl/
// revoked.krl); plain keys never (AuthorizedKeysFile none). The certificate's principals are
// matched against the lines `tando-gate ctl-principals` prints (AuthorizedPrincipalsCommand, run
// by sshd as tando-keys), each with its forced command:
//
//	tando-ctl-write    <gate> ctl write <serial> <key id>
//	tando-app-<app>    <gate> ctl app:<app> <serial> <key id>   (one line per app on the node)
//	tando-ctl-read     <gate> ctl read <serial> <key id>
//
// sshd takes the first line whose principal the certificate carries, in this order. The forced
// command reaches the login shell as "-c <command>": ctl mode (Ctl) reads one request from stdin
// and hands it, unchanged, to root mode through the single sudo rule `<gate> ctl-root`. Root mode
// (CtlRoot) takes the mode from the session's login process, set by sshd (session.go), never
// from the caller, and srv/ctl answers.

const (
	ctlUser    = "tando-ctl"
	ctlSSHDrop = "/etc/ssh/sshd_config.d/50-tando-ctl.conf"
	ctlSudo    = "tando-ctl"
	// ctlMaxRequest is srv/ctl's MaxRequest (the gate does not import srv/ctl).
	ctlMaxRequest = 256 << 10
)

// CtlIdent is what root mode learned from the session: the principal's mode, the app of an app
// principal, the certificate's serial and key id.
type CtlIdent struct {
	Mode, App, Serial, KeyID string
}

func (g *Gate) ctlDir() string { return filepath.Join(g.P.Root, "ctl") }

var (
	ctlSerialRe = regexp.MustCompile(`^[0-9]{1,20}$`)
	ctlKeyIDRe  = regexp.MustCompile(`^[A-Za-z0-9._@+:-]{1,64}$`)
)

// ctlSafe: a certificate's key id as the forced command carries it ("-": absent or unprintable).
func ctlSafe(re *regexp.Regexp, s string) string {
	if re.MatchString(s) {
		return s
	}
	return "-"
}

// ParseCtlCommand parses a forced command "<gate> ctl <mode> <serial> <key id>".
func ParseCtlCommand(cmd, gate string) (CtlIdent, bool) {
	rest, ok := strings.CutPrefix(cmd, gate+" ctl ")
	if !ok {
		return CtlIdent{}, false
	}
	f := strings.Split(rest, " ")
	if len(f) != 3 || (f[1] != "-" && !ctlSerialRe.MatchString(f[1])) || (f[2] != "-" && !ctlKeyIDRe.MatchString(f[2])) {
		return CtlIdent{}, false
	}
	id := CtlIdent{Mode: f[0], Serial: f[1], KeyID: f[2]}
	switch {
	case f[0] == "read", f[0] == "write":
	case strings.HasPrefix(f[0], "app:") && valid.App(f[0][4:]):
		id.Mode, id.App = "app", f[0][4:]
	default:
		return CtlIdent{}, false
	}
	return id, true
}

// IsCtlLogin: the login shell's arguments are a ctl forced command (main dispatches on it).
func IsCtlLogin(args []string, gate string) bool {
	// lint: allow RL16 sshd starts the login shell with "-c <command>"; this is how it is recognised, not a shell
	return len(args) == 2 && args[0] == "-c" && strings.HasPrefix(args[1], gate+" ctl ")
}

// CtlPrincipals prints the principals file for sshd (AuthorizedPrincipalsCommand <gate>
// ctl-principals %s %i), run as tando-keys.
func (g *Gate) CtlPrincipals(args []string) error {
	if len(args) != 2 {
		return die("bad call")
	}
	serial, keyID := ctlSafe(ctlSerialRe, args[0]), ctlSafe(ctlKeyIDRe, args[1])
	w := bufio.NewWriter(g.Stdout)
	line := func(mode, principal string) {
		fmt.Fprintf(w, "restrict,command=\"%s ctl %s %s %s\" %s\n", g.P.Gate, mode, serial, keyID, principal)
	}
	line("write", "tando-ctl-write")
	if ents, err := os.ReadDir(filepath.Join(g.P.Root, "apps")); err == nil {
		for _, e := range ents {
			if a := e.Name(); e.IsDir() && valid.App(a) {
				line("app:"+a, "tando-app-"+a)
			}
		}
	}
	line("read", "tando-ctl-read")
	return w.Flush()
}

// ctlCaller: uid is the control plane user exactly as CtlSetup made it.
func (g *Gate) ctlCaller(uid int) bool {
	p, ok := g.userByUID(uid)
	return ok && p.Name == ctlUser && p.Home == g.ctlDir() && p.Shell == g.P.Gate
}

// Ctl is ctl mode: tando-ctl's login shell with a principal's forced command. It reads the
// request (one JSON object, at most ctlMaxRequest bytes, within a minute) and passes it to root
// mode; the response and the exit status are root mode's.
func (g *Gate) Ctl(args []string) error {
	if g.Caller.UID == 0 || g.Caller.EUID == 0 {
		return die("ctl mode never runs as root")
	}
	if !g.ctlCaller(g.Caller.UID) || g.Caller.UID != g.Caller.EUID {
		return die("this login is not the tando control plane user")
	}
	if _, ok := ParseCtlCommand(args[1], g.P.Gate); !ok {
		return die("bad forced command")
	}
	if g.Caller.SSHCommand != "" {
		return die("the control plane sends its request on stdin, with no command (ssh %s@<node> < request.json)", ctlUser)
	}
	in, err := readCapped(g.Stdin, ctlMaxRequest+1, time.Minute)
	if err != nil {
		return die("could not read the request: %v", err)
	}
	c := run.Cmd{Argv: []string{"sudo", "-n", "--", g.P.Gate, "ctl-root"}, Stdin: bytes.NewReader(in),
		Stdout: g.Stdout, Stderr: g.Stderr, Timeout: 3 * time.Hour}
	if _, err := g.Env.Run.Output(context.Background(), c); err != nil {
		return Exit{ExitCode(err)}
	}
	return nil
}

// readCapped reads f to its end, at most max bytes, within d.
func readCapped(f *os.File, max int, d time.Duration) ([]byte, error) {
	fd, err := syscall.Dup(int(f.Fd()))
	if err != nil {
		return nil, err
	}
	syscall.CloseOnExec(fd)
	syscall.SetNonblock(fd, true)
	r := os.NewFile(uintptr(fd), "stdin")
	defer r.Close()
	r.SetReadDeadline(time.Now().Add(d))
	return io.ReadAll(io.LimitReader(r, int64(max)))
}

// CtlRoot is root mode for the control plane (sudo <gate> ctl-root): the identity from the
// session, the request from stdin. The caller (main) runs srv/ctl with them.
func (g *Gate) CtlRoot(args []string) (CtlIdent, []byte, error) {
	if g.Caller.EUID != 0 {
		return CtlIdent{}, nil, die("root mode runs through sudo")
	}
	if len(args) != 0 {
		return CtlIdent{}, nil, die("bad call")
	}
	uid, ok := uintOf(g.Caller.SudoUID)
	if !ok || uid == 0 || !g.ctlCaller(uid) {
		return CtlIdent{}, nil, die("ctl root mode is for the control plane user")
	}
	if !fsinfo.RegularFollow(filepath.Join(g.ctlDir(), "ca.pub")) {
		return CtlIdent{}, nil, die("control plane mode is off on this node (tando host setup <host> ctl_ca=...)")
	}
	k, a, err := g.loginProcess(uid)
	if err != nil {
		return CtlIdent{}, nil, err
	}
	// lint: allow RL16 sshd starts the login shell with "-c <command>"
	if a[1] != "-c" {
		return CtlIdent{}, nil, die(msgSession)
	}
	id, ok := ParseCtlCommand(a[2], g.P.Gate)
	if !ok {
		return CtlIdent{}, nil, die(msgSession)
	}
	// the command line is only as good as the way in: sshd's own record of it must be one
	// certificate of this node's CA with that mode's principal (ctlcert.go)
	c, err := g.authInfo(k, uid)
	if err != nil {
		return CtlIdent{}, nil, err
	}
	if !g.certAllows(c, id) {
		return CtlIdent{}, nil, die("ctl root mode: the session's certificate does not grant %s", id.Mode)
	}
	in, err := io.ReadAll(io.LimitReader(g.Stdin, ctlMaxRequest+1))
	if err != nil {
		return CtlIdent{}, nil, die("could not read the request")
	}
	return id, in, nil
}

// Log writes one line to the journal (auth facility).
func (g *Gate) Log(msg string) { g.log("auth.info", msg) }

// ---- admin: ctl-setup, ctl-krl, ctl-off -----------------------------------------------------

// caTypes: the key types a CA may have, and how many length-prefixed fields their blob holds
// (the type included).
var caTypes = map[string]int{
	"ssh-ed25519": 2, "ecdsa-sha2-nistp256": 3, "ecdsa-sha2-nistp384": 3, "ecdsa-sha2-nistp521": 3,
	"ssh-rsa": 3, "sk-ssh-ed25519@openssh.com": 3, "sk-ecdsa-sha2-nistp256@openssh.com": 4,
}

// ParseCAKey checks a CA public key line ("<type> <base64> [comment]"): a known type whose blob
// names the same type. It returns "<type> <base64>" (no comment).
func ParseCAKey(line string) (string, bool) {
	f := strings.Fields(line)
	if len(f) < 2 || caTypes[f[0]] == 0 || len(f[1]) > 4096 {
		return "", false
	}
	b, err := base64.StdEncoding.DecodeString(f[1])
	if err != nil {
		return "", false
	}
	// the blob is exactly its fields: the type again, then the key's own (a cut key is refused)
	var fields [][]byte
	for len(b) > 0 {
		if len(b) < 4 {
			return "", false
		}
		n := binary.BigEndian.Uint32(b)
		if uint64(n) > uint64(len(b)-4) {
			return "", false
		}
		fields, b = append(fields, b[4:4+n]), b[4+n:]
	}
	if len(fields) != caTypes[f[0]] || string(fields[0]) != f[0] || (f[0] == "ssh-ed25519" && len(fields[1]) != 32) {
		return "", false
	}
	return f[0] + " " + f[1], true
}

func ctlDropIn(gate, dir string) []byte {
	return fmt.Appendf(nil, `# tando control plane: certificates of the control plane's CA only; the principal picks the
# forced command (managed by tando-gate: tando host setup <host> ctl_ca=...)
Match User %[3]s
	AuthenticationMethods publickey
	PubkeyAuthentication yes
	PasswordAuthentication no
	KbdInteractiveAuthentication no
	HostbasedAuthentication no
	GSSAPIAuthentication no
	ExposeAuthInfo yes
	AuthorizedKeysFile none
	TrustedUserCAKeys %[2]s/ca.pub
	RevokedKeys %[2]s/revoked.krl
	AuthorizedPrincipalsFile none
	AuthorizedPrincipalsCommand %[1]s ctl-principals %%s %%i
	AuthorizedPrincipalsCommandUser %[4]s
	DisableForwarding yes
	PermitTTY no
	PermitUserRC no
	PermitTunnel no
	X11Forwarding no
	AllowAgentForwarding no
	AllowTcpForwarding no
	AllowStreamLocalForwarding no
	SetEnv LC_ALL=C LANG=C
	MaxSessions 8
`, gate, dir, ctlUser, keysUser)
}

func ctlSudoRule(gate string, tty bool) []byte {
	t := ""
	if tty {
		t = "!requiretty, "
	}
	return fmt.Appendf(nil, `# tando control plane user: its root mode, nothing else (managed by tando-gate)
Defaults:%[1]s %[2]senv_reset, !lecture
%[1]s ALL=(root) NOPASSWD: %[3]s ctl-root
`, ctlUser, t, gate)
}

// CtlAdmin: ctl-setup (stdin: the CA's public key), ctl-krl (stdin: an OpenSSH KRL), ctl-off.
func (g *Gate) CtlAdmin(w *out.Writer, verb string) error {
	switch verb {
	case "ctl-setup":
		line, _ := readPiece(bufio.NewReader(g.Stdin), 8192)
		ca, ok := ParseCAKey(line)
		if !ok {
			return die("ctl_ca: not an OpenSSH public key (ssh-ed25519 AAAA..., the CA's .pub)")
		}
		return g.ctlSetup(w, ca)
	case "ctl-krl":
		data, err := io.ReadAll(io.LimitReader(g.Stdin, 16<<20+1))
		if err != nil || len(data) > 16<<20 {
			return die("the revocation list is unreadable or over 16 MB")
		}
		return g.ctlKRL(w, data)
	case "ctl-off":
		return g.ctlOff(w)
	case "ctl-check":
		if !fsinfo.RegularFollow(filepath.Join(g.ctlDir(), "ca.pub")) {
			w.KV("ctl", "off")
			return nil
		}
		if err := g.ctlCheck(); err != nil {
			return err
		}
		w.KV("ctl", "ok")
		return nil
	}
	return die("unknown admin verb")
}

func (g *Gate) ctlSetup(w *out.Writer, ca string) error {
	fi, err := os.Stat(g.P.Gate)
	if err != nil || fi.Mode()&0o7777 != 0o755 || ownerUID(fi) != 0 {
		return die("%s must be root-owned, mode 755", g.P.Gate)
	}
	dir := g.ctlDir()
	if err := mkdirExact(dir, 0o755, g.Owner, g.Group); err != nil {
		return err
	}
	if err := atomicfile.Write(filepath.Join(dir, "ca.pub"), []byte(ca+"\n"), atomicfile.Mode(0o644)); err != nil {
		return err
	}
	krl := filepath.Join(dir, "revoked.krl")
	if !fsinfo.RegularFollow(krl) { // an empty list revokes nothing; a missing one would refuse every certificate
		if err := writeNew(krl, nil, 0o644); err != nil {
			return err
		}
	}
	t := 60 * time.Second
	if _, ok := g.userByName(keysUser); !ok {
		if _, err := g.quiet(t, "useradd", "--system", "--user-group", "--no-create-home", "--home-dir", "/nonexistent",
			"--shell", "/usr/sbin/nologin", "--comment", "tando sshd reads CI keys as this user", "--", keysUser); err != nil {
			return die("useradd %s failed", keysUser)
		}
	}
	if p, ok := g.userByName(ctlUser); !ok {
		if _, err := g.quiet(t, "useradd", "--system", "--user-group", "--no-create-home", "--home-dir", dir,
			"--shell", g.P.Gate, "--comment", "tando control plane", "--", ctlUser); err != nil {
			return die("useradd %s failed", ctlUser)
		}
	} else if p.Home != dir || p.Shell != g.P.Gate {
		return die("user %s exists but was not created by tando-gate", ctlUser)
	}
	g.quiet(t, "usermod", "-p", "*", "--", ctlUser) // no password, not "locked": sshd accepts its certificates
	if err := g.writeSudoersFile(ctlSudo, func(tty bool) []byte { return ctlSudoRule(g.P.Gate, tty) }); err != nil {
		return err
	}
	if err := g.installDrop(ctlDropIn(g.P.Gate, dir)); err != nil {
		return err
	}
	w.KV("ok", "1")
	if o, err := g.quiet(t, "ssh-keygen", "-l", "-f", filepath.Join(dir, "ca.pub")); err == nil {
		if f := strings.Fields(string(o)); len(f) > 1 {
			w.KV("ca", f[1])
		}
	}
	return nil
}

func (g *Gate) ctlKRL(w *out.Writer, data []byte) error {
	dir := g.ctlDir()
	if !fsinfo.RegularFollow(filepath.Join(dir, "ca.pub")) {
		return die("control plane mode is off: set it up first (ctl_ca=)")
	}
	tmp := filepath.Join(dir, ".revoked.krl.new")
	if err := writeNew(tmp, data, 0o644); err != nil {
		return err
	}
	defer os.Remove(tmp)
	// an unreadable list would make sshd refuse every certificate: only a KRL ssh-keygen reads,
	// or an empty file (revokes nothing)
	if _, err := g.Env.Run.Output(context.Background(), run.Cmd{Argv: []string{"ssh-keygen", "-Q", "-l", "-f", tmp},
		Timeout: 30 * time.Second}); err != nil && len(data) > 0 {
		return die("not an OpenSSH key revocation list (ssh-keygen -k makes one): %s", clean(err.Error()))
	}
	if err := os.Rename(tmp, filepath.Join(dir, "revoked.krl")); err != nil {
		return err
	}
	w.KV("ok", "1")
	w.KV("bytes", fmt.Sprint(len(data)))
	return nil
}

func (g *Gate) ctlOff(w *out.Writer) error {
	if err := os.Remove(ctlSSHDropPath(g)); err == nil {
		g.reloadSSHD()
	}
	os.Remove(filepath.Join(g.P.Sudoers, ctlSudo))
	os.Remove(filepath.Join(g.ctlDir(), "ca.pub"))
	w.KV("ok", "1")
	return nil
}

func ctlSSHDropPath(g *Gate) string {
	return filepath.Join(filepath.Dir(g.P.SSHDDrop), filepath.Base(ctlSSHDrop))
}

// installDrop writes an sshd drop-in when it differs, checks it with sshd -t (the old one comes
// back when sshd rejects it) and reloads sshd.
func (g *Gate) installDrop(want []byte) error {
	p := ctlSSHDropPath(g)
	if !fsinfo.DirNoFollow(filepath.Dir(p)) {
		return die("no %s: control plane mode needs OpenSSH's drop-in directory", filepath.Dir(p))
	}
	old, oerr := os.ReadFile(p)
	if oerr == nil && bytes.Equal(old, want) {
		return nil
	}
	if err := atomicfile.Write(p, want, atomicfile.Mode(0o644)); err != nil {
		return err
	}
	if o, err := g.Env.Run.Output(context.Background(), run.Cmd{Argv: []string{"sshd", "-t"}, Timeout: 30 * time.Second}); err != nil {
		if oerr == nil {
			atomicfile.Write(p, old, atomicfile.Mode(0o644))
		} else {
			os.Remove(p)
		}
		return die("sshd rejected the control plane drop-in: %s", clean(strings.TrimSpace(string(o))+" "+err.Error()))
	}
	if err := g.ctlCheck(); err != nil {
		if oerr == nil {
			atomicfile.Write(p, old, atomicfile.Mode(0o644))
		} else {
			os.Remove(p)
		}
		return err
	}
	g.reloadSSHD()
	return nil
}

// ctlConns: the connections sshd -T is asked about: loopback, a private and a public address,
// on each port sshd listens on (a Match Address or LocalPort block elsewhere must not open
// another way in for any of them).
var ctlConns = []string{"127.0.0.1", "10.11.12.13", "203.0.113.10"}

// ctlCheck: what sshd will do for tando-ctl, all files and drop-ins together, is the drop-in's
// (certificates of the CA, principals from the gate, no other way in). Run by ctl-setup, by
// `tando-gate admin ctl-check` (tando doctor) and by every host setup while the mode is on.
func (g *Gate) ctlCheck() error {
	o, err := g.Env.Run.Output(context.Background(), run.Cmd{Argv: []string{"sshd", "-T"}, Timeout: 30 * time.Second})
	if err != nil {
		return die("sshd -T failed: %s", clean(err.Error()))
	}
	var ports []string
	for l := range strings.SplitSeq(string(o), "\n") {
		if p, ok := strings.CutPrefix(l, "port "); ok && ctlSerialRe.MatchString(p) && len(ports) < 4 {
			ports = append(ports, p)
		}
	}
	if len(ports) == 0 {
		ports = []string{"22"}
	}
	for _, a := range ctlConns {
		for _, port := range ports {
			spec := "user=" + ctlUser + ",host=" + a + ",addr=" + a + ",laddr=" + a + ",lport=" + port
			o, err := g.Env.Run.Output(context.Background(), run.Cmd{Argv: []string{"sshd", "-T", "-C", spec}, Timeout: 30 * time.Second})
			why := ctlEffective(o, g.P.Gate, g.ctlDir())
			if err != nil && why == "" {
				why = "sshd -T failed"
			}
			if why != "" {
				return die("sshd would not apply the control plane settings for %s from %s to port %s (%s): another sshd_config file sets them first, or adds a way in", ctlUser, a, port, why)
			}
		}
	}
	return nil
}

// ctlEffective checks sshd -T's settings for one tando-ctl connection; "" when they are the
// drop-in's. Optional ones may be missing (an sshd built without GSSAPI does not print it).
func ctlEffective(t []byte, gate, dir string) string {
	want := []struct {
		k, v     string
		optional bool
	}{
		{"authenticationmethods", "publickey", false},
		{"pubkeyauthentication", "yes", false},
		{"passwordauthentication", "no", false},
		{"kbdinteractiveauthentication", "no", false},
		{"hostbasedauthentication", "no", false},
		{"gssapiauthentication", "no", true},
		{"authorizedkeysfile", "none", false},
		{"authorizedkeyscommand", "none", false},
		{"trustedusercakeys", dir + "/ca.pub", false},
		{"revokedkeys", dir + "/revoked.krl", false},
		{"authorizedprincipalsfile", "none", false},
		{"authorizedprincipalscommand", gate + " ctl-principals %s %i", false},
		{"authorizedprincipalscommanduser", keysUser, false},
		{"forcecommand", "none", false},
		{"exposeauthinfo", "yes", false},
		{"disableforwarding", "yes", false},
		{"permittty", "no", false},
	}
	got := map[string]string{}
	for l := range strings.SplitSeq(string(t), "\n") {
		k, v, _ := strings.Cut(strings.TrimSpace(l), " ")
		got[strings.ToLower(k)] = v
	}
	for _, w := range want {
		v, ok := got[w.k]
		if (!ok && w.optional) || v == w.v {
			continue
		}
		return w.k + " " + or(v, "unset")
	}
	return ""
}

func or(s, def string) string {
	if s == "" {
		return def
	}
	return s
}

func (g *Gate) reloadSSHD() {
	if _, err := g.quiet(30*time.Second, "systemctl", "reload", "ssh"); err != nil {
		if _, err := g.quiet(30*time.Second, "systemctl", "reload", "sshd"); err != nil {
			fmt.Fprintln(g.Stderr, "warning=could not reload sshd")
		}
	}
}

// writeSudoersFile installs /etc/sudoers.d/<name> as writeSudoers does (with requiretty off,
// then without the setting; never a rule visudo rejects).
func (g *Gate) writeSudoersFile(name string, rule func(tty bool) []byte) error {
	sf := filepath.Join(g.P.Sudoers, name)
	tmp := sf + ".tmp"
	for _, tty := range []bool{true, false} {
		if err := writeNew(tmp, rule(tty), 0o440); err != nil {
			return err
		}
		// lint: allow RL16 visudo's -c is "check only", not a shell's
		if _, err := g.quiet(30*time.Second, "visudo", "-c", "-q", "-f", tmp); err == nil {
			return os.Rename(tmp, sf)
		}
	}
	os.Remove(tmp)
	return die("visudo rejected the rule")
}
