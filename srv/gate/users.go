package gate

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	"tando/srv/internal/atomicfile"
	"tando/srv/internal/bashread"
	"tando/srv/internal/decimal"
	"tando/srv/internal/fsinfo"
)

// newUID is an id for a new user from tando's band (host.conf uid_min-uid_max, default
// 30000-39999; tando-agent's new_uid): no user or group has it (passwd and group read once with
// getent, then the one picked asked of NSS by number, as useradd does), and no removed user had
// it (retired-uids: files a removed user left where tando does not clean must never belong to a
// later one) while the band has others; then the retired ones are used again, oldest first.
func (g *Gate) newUID() (int, error) {
	retired, _ := os.ReadFile(filepath.Join(g.P.Root, "retired-uids"))
	hc, _ := os.ReadFile(filepath.Join(g.P.Root, "host.conf"))
	lo, hi := 30000, 39999
	if a, ok := decimal.Parse(kvOf(hc, "uid_min"), 9); ok {
		if b, ok := decimal.Parse(kvOf(hc, "uid_max"), 9); ok && a <= b {
			lo, hi = int(a), int(b)
		}
	}
	used := map[string]bool{}
	for _, db := range []string{"passwd", "group"} {
		out, _ := g.quiet(30*time.Second, "getent", db)
		for _, l := range bashread.LinesAll(out) {
			if f := bytes.Split([]byte(l), []byte(":")); len(f) > 2 {
				used[string(f[2])] = true
			}
		}
	}
	free := func(s string) bool {
		if used[s] {
			return false
		}
		if _, err := g.quiet(10*time.Second, "getent", "passwd", "--", s); err == nil {
			return false
		}
		_, err := g.quiet(10*time.Second, "getent", "group", "--", s)
		return err != nil
	}
	for u := lo; u <= hi; u++ {
		if s := strconv.Itoa(u); !lineIn(retired, s) && free(s) {
			return u, nil
		}
	}
	for _, s := range bashread.LinesAll(retired) {
		if n, ok := decimal.Parse(s, 9); ok && int(n) >= lo && int(n) <= hi && free(s) {
			return int(n), nil
		}
	}
	return 0, die("no free uid left in %d-%d (uid_min, uid_max in tando host setup)", lo, hi)
}

// lineIn: data has a line that is exactly s (grep -qx).
func lineIn(data []byte, s string) bool {
	for _, l := range bashread.LinesAll(data) {
		if l == s {
			return true
		}
	}
	return false
}

// appendLine appends s as a line of its own (>>), creating the file with mode; a last line
// without a newline is ended first.
func appendLine(path, s string, mode os.FileMode) error {
	f, err := os.OpenFile(path, os.O_RDWR|os.O_APPEND|os.O_CREATE|syscall.O_NOFOLLOW, mode)
	if err != nil {
		return err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return err
	}
	b := []byte(s + "\n")
	if fi.Size() > 0 {
		last := make([]byte, 1)
		if _, err := f.ReadAt(last, fi.Size()-1); err == nil && last[0] != '\n' {
			b = append([]byte{'\n'}, b...)
		}
	}
	_, err = f.Write(b)
	return err
}

// denyList adds the user to /etc/cron.deny or /etc/at.deny, or removes it.
func (g *Gate) denyList(path, user string, add bool) error {
	data, err := os.ReadFile(path)
	if add {
		if err != nil && !os.IsNotExist(err) {
			return err
		}
		if lineIn(data, user) {
			return nil
		}
		return appendLine(path, user, 0o644)
	}
	if err != nil {
		return nil
	}
	var b bytes.Buffer
	for _, l := range bashread.LinesAll(data) {
		if l != user {
			b.WriteString(l)
			b.WriteByte('\n')
		}
	}
	return atomicfile.Write(path, b.Bytes(), atomicfile.Mode(0o644))
}

// ensureUser makes the deploy user of app what it must be: the user, its root-owned home and key
// file, its exact sudo rule, no user manager, no cron or at, and ownership of the app's
// persistent incoming/. Run at every key-add and host setup, so existing users get the current
// layout too.
func (g *Gate) ensureUser(app string) error {
	u, h := "tando-d-"+app, g.home(app)
	t := 60 * time.Second
	if _, ok := g.userByName(u); !ok {
		uid, err := g.newUID()
		if err != nil {
			return err
		}
		if _, err := g.quiet(t, "useradd", "--system", "--user-group", "--no-create-home", "--home-dir", h,
			"--shell", g.P.Gate, "-u", strconv.Itoa(uid), "--comment", "tando CI deploys for "+app, "--", u); err != nil {
			return die("useradd failed")
		}
		g.quiet(t, "usermod", "-p", "*", "--", u) // no password, but not "locked": sshd may still accept its keys
	}
	pw, ok := g.userByName(u)
	if !ok {
		return die("useradd failed")
	}
	if a, ok := g.CallerApp(pw.UID); !ok || a != app {
		return die("user %s exists but was not created by tando-gate", u)
	}
	// the app's metadata group (tando-agent): status, releases and history of its own app only
	if _, err := g.quiet(t, "getent", "group", "--", "tando-m-"+app); err == nil {
		g.quiet(t, "usermod", "-aG", "tando-m-"+app, "--", u)
	}
	// home: traversable, not listable; .ssh: the key file, readable by root and sshd's key reader
	for _, d := range []struct {
		p string
		m os.FileMode
	}{{h, 0o711}, {filepath.Join(h, ".ssh"), 0o711}, {filepath.Join(h, "state"), 0o700}} {
		if err := mkdirExact(d.p, d.m, g.Owner, g.Group); err != nil {
			return err
		}
	}
	keys := filepath.Join(h, "keys")
	if !fsinfo.RegularFollow(keys) {
		if err := writeNew(keys, nil, 0o600); err != nil {
			return err
		}
	}
	kg := g.groupGID(keysUser)
	if kg < 0 {
		return die("no group %s", keysUser)
	}
	ak := filepath.Join(h, ".ssh", "authorized_keys")
	if !fsinfo.RegularFollow(ak) {
		if err := writeNew(ak, nil, 0o640); err != nil {
			return err
		}
	}
	if err := os.Lchown(ak, g.Owner, kg); err != nil {
		return err
	}
	if err := os.Chmod(ak, 0o640); err != nil {
		return err
	}
	if fr := filepath.Join(h, "frozen"); fsinfo.RegularFollow(fr) {
		os.Chmod(fr, 0o600)
	}
	if err := g.writeSudoers(app); err != nil {
		return err
	}
	// nothing runs as the deploy user outside its ssh requests: no systemd user manager (it would
	// load units from /run/user/<uid>), no lingering, no cron, no at
	g.quiet(t, "systemctl", "mask", "--quiet", "--", fmt.Sprintf("user@%d.service", pw.UID))
	g.quiet(t, "loginctl", "disable-linger", "--", u)
	if err := g.denyList(g.P.CronDeny, u, true); err != nil {
		return err
	}
	if err := g.denyList(g.P.AtDeny, u, true); err != nil {
		return err
	}
	// incoming/ is handed over once, while it is still the admin's: root never walks a tree the
	// deploy user can already change (links themselves, never followed)
	inc := g.incoming(app)
	if owner, err := ownerOf(inc); err != nil || int(owner) != pw.UID {
		if err != nil || chownTree(inc, pw.UID, pw.GID) != nil {
			return die("could not hand incoming/ to %s", u)
		}
	}
	chmodDir(inc, 0o700)
	return nil
}

// writeKeys rebuilds authorized_keys from the key list: one line per active key.
func (g *Gate) writeKeys(app string) error {
	h := g.home(app)
	data, err := os.ReadFile(filepath.Join(h, "keys"))
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	kg := g.groupGID(keysUser)
	if kg < 0 {
		return die("no group %s", keysUser)
	}
	return atomicfile.Write(filepath.Join(h, ".ssh", "authorized_keys"), AuthorizedKeys(data, g.P.Gate, app),
		atomicfile.Perm{Mode: 0o640, UID: -1, GID: kg})
}

// removeUser: the app is being destroyed: deploy user, sudo rule, home; the uid is retired.
func (g *Gate) removeUser(app string) error {
	u := "tando-d-" + app
	os.Remove(filepath.Join(g.P.Sudoers, u))
	if pw, ok := g.userByName(u); ok {
		if a, ok := g.CallerApp(pw.UID); (!ok || a != app) && fsinfo.RegularFollow(filepath.Join(g.appDir(app), "app.conf")) {
			return die("user %s was not created by tando-gate", u)
		}
		g.evictUser(app)
		t := 60 * time.Second
		g.quiet(t, "systemctl", "unmask", "--quiet", "--", fmt.Sprintf("user@%d.service", pw.UID))
		g.denyList(g.P.CronDeny, u, false)
		g.denyList(g.P.AtDeny, u, false)
		g.quiet(t, "userdel", "--", u)
		if _, err := g.quiet(t, "getent", "group", "--", u); err == nil {
			g.quiet(t, "groupdel", "--", u)
		}
		rf := filepath.Join(g.P.Root, "retired-uids")
		retired, _ := os.ReadFile(rf)
		if s := strconv.Itoa(pw.UID); !lineIn(retired, s) {
			appendLine(rf, s, 0o644)
		}
	}
	os.RemoveAll(g.home(app))
	return nil
}
