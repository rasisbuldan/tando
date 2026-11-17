package gate

import (
	"os"
	"path/filepath"
	"strings"

	"tando/srv/internal/fsinfo"
	"tando/srv/internal/valid"
)

// Passwd is one line of /etc/passwd.
type Passwd struct {
	Name        string
	UID, GID    int
	Home, Shell string
}

// parseColon splits a passwd/group line into exactly n fields.
func parseColon(l string, n int) ([]string, bool) {
	f := strings.Split(l, ":")
	if len(f) != n {
		return nil, false
	}
	return f, true
}

// ParsePasswd reads passwd lines; malformed lines are skipped. Only the local file is read:
// a deploy user is always a local system user (useradd), so a user that exists only in another
// NSS source (LDAP) is never taken for one.
func ParsePasswd(data []byte) []Passwd {
	var r []Passwd
	for l := range strings.SplitSeq(string(data), "\n") {
		f, ok := parseColon(l, 7)
		if !ok {
			continue
		}
		uid, ok1 := uintOf(f[2])
		gid, ok2 := uintOf(f[3])
		if !ok1 || !ok2 {
			continue
		}
		r = append(r, Passwd{Name: f[0], UID: uid, GID: gid, Home: f[5], Shell: f[6]})
	}
	return r
}

// userByUID is the first passwd entry with that uid (getent passwd <uid>).
func (g *Gate) userByUID(uid int) (Passwd, bool) {
	data, err := os.ReadFile(g.P.Passwd)
	if err != nil {
		return Passwd{}, false
	}
	for _, p := range ParsePasswd(data) {
		if p.UID == uid {
			return p, true
		}
	}
	return Passwd{}, false
}

// userByName is the first passwd entry with that name (getent passwd <name>, id -u <name>).
func (g *Gate) userByName(name string) (Passwd, bool) {
	data, err := os.ReadFile(g.P.Passwd)
	if err != nil {
		return Passwd{}, false
	}
	for _, p := range ParsePasswd(data) {
		if p.Name == name {
			return p, true
		}
	}
	return Passwd{}, false
}

// groupGID is the gid of a local group, -1 if there is none.
func (g *Gate) groupGID(name string) int {
	data, err := os.ReadFile(g.P.Group)
	if err != nil {
		return -1
	}
	for l := range strings.SplitSeq(string(data), "\n") {
		f, ok := parseColon(l, 4)
		if !ok || f[0] != name {
			continue
		}
		if gid, ok := uintOf(f[2]); ok {
			return gid
		}
	}
	return -1
}

// CallerApp is the app of a deploy user's uid (caller_app): the passwd entry must be exactly
// what ensureUser created: name tando-d-<app>, home CI/<app>, shell this program, a valid app
// name, and the app must exist.
func (g *Gate) CallerApp(uid int) (string, bool) {
	p, ok := g.userByUID(uid)
	if !ok {
		return "", false
	}
	app, ok := strings.CutPrefix(p.Name, "tando-d-")
	if !ok || !valid.App(app) {
		return "", false
	}
	if p.Home != filepath.Join(g.P.CI, app) || p.Shell != g.P.Gate {
		return "", false
	}
	return app, fsinfo.RegularFollow(filepath.Join(g.appDir(app), "app.conf"))
}
