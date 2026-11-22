package gate

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
)

// The login's own proof. The mode on the login's command line is what the principals command
// forced, but only when sshd admitted the login by a certificate: any other way in (GSSAPI,
// hostbased, keyboard-interactive through PAM) has no forced command, and its client could name
// any mode. So root mode also reads what sshd says authenticated the session (ExposeAuthInfo:
// SSH_USER_AUTH in the login's environment names a file sshd wrote) and requires exactly one
// method, publickey with a certificate of the node's CA that carries the principal of the claimed
// mode and the serial and key id the command line names.

// Cert is what root mode reads from an OpenSSH certificate (PROTOCOL.certkeys).
type Cert struct {
	Type        string
	Serial      uint64
	KeyID       string
	Principals  []string
	ValidBefore uint64
	CAKey       []byte // the signature key's blob
}

// certKeyFields: how many length-prefixed fields the certified key has, per certificate type.
var certKeyFields = map[string]int{
	"ssh-ed25519-cert-v01@openssh.com":            1,
	"ecdsa-sha2-nistp256-cert-v01@openssh.com":    2,
	"ecdsa-sha2-nistp384-cert-v01@openssh.com":    2,
	"ecdsa-sha2-nistp521-cert-v01@openssh.com":    2,
	"ssh-rsa-cert-v01@openssh.com":                2,
	"sk-ssh-ed25519-cert-v01@openssh.com":         2,
	"sk-ecdsa-sha2-nistp256-cert-v01@openssh.com": 3,
}

type wire struct {
	b  []byte
	ok bool
}

func (w *wire) str() []byte {
	if !w.ok || len(w.b) < 4 {
		w.ok = false
		return nil
	}
	n := binary.BigEndian.Uint32(w.b)
	if uint64(n) > uint64(len(w.b)-4) {
		w.ok = false
		return nil
	}
	s := w.b[4 : 4+n]
	w.b = w.b[4+n:]
	return s
}

func (w *wire) u64() uint64 {
	if !w.ok || len(w.b) < 8 {
		w.ok = false
		return 0
	}
	v := binary.BigEndian.Uint64(w.b)
	w.b = w.b[8:]
	return v
}

func (w *wire) u32() uint32 {
	if !w.ok || len(w.b) < 4 {
		w.ok = false
		return 0
	}
	v := binary.BigEndian.Uint32(w.b)
	w.b = w.b[4:]
	return v
}

// ParseCert reads a user certificate's blob.
func ParseCert(blob []byte) (Cert, bool) {
	w := &wire{b: blob, ok: true}
	c := Cert{Type: string(w.str())}
	n, known := certKeyFields[c.Type]
	if !known {
		return Cert{}, false
	}
	w.str() // nonce
	for range n {
		w.str()
	}
	c.Serial = w.u64()
	if w.u32() != 1 { // SSH_CERT_TYPE_USER
		return Cert{}, false
	}
	c.KeyID = string(w.str())
	pw := &wire{b: w.str(), ok: w.ok}
	for pw.ok && len(pw.b) > 0 {
		c.Principals = append(c.Principals, string(pw.str()))
	}
	w.u64() // valid after
	c.ValidBefore = w.u64()
	w.str() // critical options
	w.str() // extensions
	w.str() // reserved
	c.CAKey = slices.Clone(w.str())
	w.str() // signature
	if !w.ok || !pw.ok || len(w.b) != 0 {
		return Cert{}, false
	}
	return c, true
}

// authInfo reads the login's SSH_USER_AUTH file: exactly one method, publickey with a
// certificate. The file is sshd's (in /tmp, owned by the login's user, not a link).
func (g *Gate) authInfo(pid, uid int) (Cert, error) {
	refused := die("ctl root mode: the session was not authenticated by a control plane certificate")
	environ, err := os.ReadFile(g.procFile(pid, "environ"))
	if err != nil {
		return Cert{}, refused
	}
	path := ""
	for e := range bytes.SplitSeq(environ, []byte{0}) {
		if v, ok := bytes.CutPrefix(e, []byte("SSH_USER_AUTH=")); ok {
			path = string(v)
		}
	}
	if !strings.HasPrefix(path, filepath.Join(g.P.AuthTmp, "sshauth.")) || strings.Contains(path, "/../") {
		return Cert{}, refused
	}
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return Cert{}, refused
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil || !fi.Mode().IsRegular() || ownerUID(fi) != uid || fi.Size() > 64<<10 {
		return Cert{}, refused
	}
	data := make([]byte, fi.Size())
	if _, err := f.ReadAt(data, 0); err != nil && fi.Size() > 0 {
		return Cert{}, refused
	}
	lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	if len(lines) != 1 {
		return Cert{}, refused
	}
	fl := strings.Fields(lines[0])
	if len(fl) != 3 || fl[0] != "publickey" {
		return Cert{}, refused
	}
	blob, err := base64.StdEncoding.DecodeString(fl[2])
	if err != nil {
		return Cert{}, refused
	}
	c, ok := ParseCert(blob)
	if !ok || c.Type != fl[1] {
		return Cert{}, refused
	}
	return c, nil
}

// certAllows: the certificate is the node CA's, valid now, carries the claimed mode's principal,
// and the serial and key id on the command line are its own.
func (g *Gate) certAllows(c Cert, id CtlIdent) bool {
	ca, err := os.ReadFile(filepath.Join(g.ctlDir(), "ca.pub"))
	if err != nil {
		return false
	}
	f := strings.Fields(string(ca))
	if len(f) < 2 {
		return false
	}
	blob, err := base64.StdEncoding.DecodeString(f[1])
	if err != nil || !bytes.Equal(blob, c.CAKey) {
		return false
	}
	if c.ValidBefore != 0xffffffffffffffff && uint64(g.now()) >= c.ValidBefore {
		return false
	}
	want := "tando-ctl-" + id.Mode
	if id.Mode == "app" {
		want = "tando-app-" + id.App
	}
	if !slices.Contains(c.Principals, want) {
		return false
	}
	return id.Serial == strconv.FormatUint(c.Serial, 10) && id.KeyID == ctlSafe(ctlKeyIDRe, c.KeyID)
}
