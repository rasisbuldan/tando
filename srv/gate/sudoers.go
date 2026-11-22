package gate

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

// sudoersRule is the deploy user's sudo rule: the gate's root mode for its own app, six exact
// argvs (the preview verbs take their name on stdin, checked by root mode), nothing else. tty: whether to switch requiretty off.
func sudoersRule(gate, app string, tty bool) []byte {
	u := "tando-d-" + app
	t := ""
	if tty {
		t = "!requiretty, "
	}
	return fmt.Appendf(nil, `# tando CI deploy user for %[1]s: exact commands, nothing else (managed by tando-gate)
Defaults:%[2]s %[3]senv_reset, !lecture
%[2]s ALL=(root) NOPASSWD: %[4]s root %[1]s begin, %[4]s root %[1]s end, %[4]s root %[1]s activate, %[4]s root %[1]s receive, %[4]s root %[1]s preview-up, %[4]s root %[1]s preview-rm
`, app, u, t, gate)
}

// writeSudoers installs the rule. sudo-rs (Ubuntu 26.04) does not know requiretty and rejects the
// whole file; classic sudo needs it switched off where a distribution turns it on. Try with it,
// then without; a rule visudo does not accept is never installed. The candidate is written as
// "<file>.tmp" (sudo skips names with a dot), 440, then renamed over the rule.
func (g *Gate) writeSudoers(app string) error {
	sf := filepath.Join(g.P.Sudoers, "tando-d-"+app)
	tmp := sf + ".tmp"
	for _, tty := range []bool{true, false} {
		if err := writeNew(tmp, sudoersRule(g.P.Gate, app, tty), 0o440); err != nil {
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

// writeNew writes path from scratch: whatever is there (a file, a symlink) is removed first and
// the new file is created exclusively, root-owned, with exactly mode.
func writeNew(path string, data []byte, mode os.FileMode) error {
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return err
	}
	_, err = f.Write(data)
	if err == nil {
		err = f.Sync()
	}
	if err == nil {
		err = f.Chmod(mode)
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		os.Remove(path)
	}
	return err
}
