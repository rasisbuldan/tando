package gate

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"tando/srv/internal/atomicfile"
	"tando/srv/internal/fsinfo"
)

// sshdDropIn is the sshd drop-in for deploy users: keys from a file they cannot read, no
// forwarding, no tty, no client locale. Byte for byte the shell version's, so a server set up
// by it sees no change.
func sshdDropIn() []byte {
	return fmt.Appendf(nil, `# tando CI deploy users: keys from a file they cannot read, no forwarding, no tty, no client
# locale (managed by tando-gate)
Match User tando-d-*
	AuthenticationMethods publickey
	PubkeyAuthentication yes
	PasswordAuthentication no
	KbdInteractiveAuthentication no
	AuthorizedKeysFile none
	AuthorizedKeysCommand /usr/bin/cat %%h/.ssh/authorized_keys
	AuthorizedKeysCommandUser %s
	DisableForwarding yes
	PermitTTY no
	PermitUserRC no
	PermitTunnel no
	X11Forwarding no
	AllowAgentForwarding no
	AllowTcpForwarding no
	AllowStreamLocalForwarding no
	SetEnv LC_ALL=C LANG=C
	MaxSessions 4
`, keysUser)
}

// installSSHD writes the drop-in when it differs, checks the whole configuration with sshd -t
// (the old file comes back when sshd rejects it) and reloads sshd.
func (g *Gate) installSSHD() error {
	p := g.P.SSHDDrop
	if !fsinfo.DirNoFollow(filepath.Dir(p)) {
		return nil
	}
	want := sshdDropIn()
	old, oerr := os.ReadFile(p)
	if oerr == nil && bytes.Equal(bytes.TrimRight(old, "\n"), bytes.TrimRight(want, "\n")) {
		return nil
	}
	oldMode := os.FileMode(0o644)
	if fi, err := os.Lstat(p); err == nil {
		oldMode = fi.Mode().Perm()
	}
	if err := atomicfile.Write(p, want, atomicfile.Mode(0o644)); err != nil {
		return err
	}
	if _, err := g.quiet(30*time.Second, "sshd", "-t"); err != nil {
		if oerr == nil {
			atomicfile.Write(p, old, atomicfile.Mode(oldMode))
		} else {
			os.Remove(p)
		}
		return die("sshd rejected the tando drop-in")
	}
	if _, err := g.quiet(30*time.Second, "systemctl", "reload", "ssh"); err != nil {
		if _, err := g.quiet(30*time.Second, "systemctl", "reload", "sshd"); err != nil {
			fmt.Fprintln(g.Stderr, "warning=could not reload sshd")
		}
	}
	return nil
}
