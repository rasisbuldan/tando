package gate

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"tando/srv/internal/bashread"
	"tando/srv/internal/fsinfo"
)

// pidsOf are the processes whose effective uid is uid (pgrep -u), from /proc.
func (g *Gate) pidsOf(uid int) []int {
	ents, err := os.ReadDir(g.Env.Proc)
	if err != nil {
		return nil
	}
	var r []int
	for _, e := range ents {
		pid, ok := uintOf(e.Name())
		if !ok || pid == 0 {
			continue
		}
		if u := g.uids(pid); u != nil && u[1] == uid {
			r = append(r, pid)
		}
	}
	return r
}

// zombie: the process has exited already (state Z after the last ") " of its stat line, so a
// ") Z" inside its name does not count).
func (g *Gate) zombie(pid int) bool {
	data, err := os.ReadFile(g.procFile(pid, "stat"))
	if err != nil {
		return false
	}
	i := bytes.LastIndex(data, []byte(") "))
	return i >= 0 && i+2 < len(data) && data[i+2] == 'Z'
}

// cgKill ends every process of a cgroup at once (cgroup.kill: atomic, forks included).
func cgKill(dir string) {
	if f, err := os.OpenFile(filepath.Join(dir, "cgroup.kill"), os.O_WRONLY, 0); err == nil {
		f.WriteString("1")
		f.Close()
	}
}

// ownCgroup is this process's cgroup (the "0::" line), "" when unknown.
func (g *Gate) ownCgroup() string {
	data, err := os.ReadFile(g.procFile(os.Getpid(), "cgroup"))
	if err != nil {
		return ""
	}
	for l := range strings.SplitSeq(string(data), "\n") {
		if v, ok := strings.CutPrefix(l, "0::"); ok {
			return v
		}
	}
	return ""
}

// stopRx ends the confined receiver of the app, if any.
func (g *Gate) stopRx(app string) {
	// the ticket first: a receiver whose unit systemd is still creating finds it gone and does
	// not start (receive.go, ticket)
	os.Remove(g.ticket(app))
	p := rxPatterns(app) // (systemctl matches the patterns against the units it has loaded)
	g.quiet(30*time.Second, append([]string{"systemctl", "kill", "--signal=KILL", "--"}, p...)...)
	g.quiet(30*time.Second, append([]string{"systemctl", "stop", "--"}, p...)...)
	g.quiet(30*time.Second, append([]string{"systemctl", "reset-failed", "--"}, p...)...)
}

// endSessions ends everything of the deploy user except this call's own ancestors (the session
// that asked, which waits for us): the receiver unit, every other session's cgroup
// (cgroup.kill: atomic, forks included), then any process of the uid left anywhere else, repeated
// until none is left. It fails (and the caller refuses to go on) when one survives 50 rounds.
func (g *Gate) endSessions(app string, uid int) error {
	anc := map[int]bool{}
	for p := os.Getpid(); p > 1; p = g.ppid(p) {
		anc[p] = true
	}
	g.stopRx(app)
	own := g.ownCgroup()
	slice := filepath.Join(g.Env.Cgroup, "user.slice", fmt.Sprintf("user-%d.slice", uid))
	n := 0
	if ents, err := os.ReadDir(slice); err == nil {
		for _, e := range ents {
			s := filepath.Join(slice, e.Name())
			if fi, err := os.Stat(s); err != nil || !fi.IsDir() {
				continue
			}
			if strings.TrimPrefix(s, g.Env.Cgroup) == own {
				continue
			}
			cgKill(s)
			n++
		}
	}
	if n > 0 {
		g.log("auth.info", fmt.Sprintf("tando-d-%s: ended %d other session(s)", app, n))
	}
	for range 50 {
		var left []int
		for _, p := range g.pidsOf(uid) {
			if anc[p] || g.zombie(p) {
				continue
			}
			left = append(left, p)
		}
		if len(left) == 0 {
			return nil
		}
		for _, p := range left {
			g.kill(p)
		}
		time.Sleep(100 * time.Millisecond)
	}
	return die("could not stop the other sessions of this key")
}

// evictUser ends everything of a deploy user: sessions (logind and cgroup.kill, which also takes
// forks), the receiver, any process left anywhere, its crontab and at jobs, IPC objects and its
// files in the world-writable temporary directories. Nothing of the user runs while this cleans.
func (g *Gate) evictUser(app string) {
	u := "tando-d-" + app
	pw, ok := g.userByName(u)
	if !ok {
		return
	}
	uid := pw.UID
	t := 30 * time.Second
	g.quiet(t, "loginctl", "terminate-user", "--", u)
	cgKill(filepath.Join(g.Env.Cgroup, "user.slice", fmt.Sprintf("user-%d.slice", uid)))
	g.quiet(t, "systemctl", "stop", "--", fmt.Sprintf("user@%d.service", uid))
	g.stopRx(app)
	for range 50 {
		p := g.pidsOf(uid)
		if len(p) == 0 {
			break
		}
		for _, x := range p {
			g.kill(x)
		}
		time.Sleep(100 * time.Millisecond)
	}
	if len(g.pidsOf(uid)) > 0 {
		fmt.Fprintf(g.Stderr, "warning=processes of %s survived the eviction\n", u)
	}
	g.quiet(t, "crontab", "-r", "-u", u)
	if out, err := g.quiet(t, "atq"); err == nil {
		for _, l := range bashread.LinesAll(out) {
			if f := strings.Fields(l); len(f) > 0 && f[len(f)-1] == u {
				g.quiet(t, "atrm", "--", f[0])
			}
		}
	}
	for _, kind := range []string{"-m", "-q", "-s"} {
		out, err := g.quiet(t, "ipcs", kind)
		if err != nil {
			continue
		}
		for _, l := range bashread.LinesAll(out) {
			if f := strings.Fields(l); len(f) >= 3 && f[2] == u {
				if _, ok := uintOf(f[1]); ok {
					g.quiet(t, "ipcrm", kind, f[1])
				}
			}
		}
	}
	// no process of the user exists any more, so nothing can race this; the walk never follows
	// a link and stays on each file system
	for _, d := range g.P.Tmp {
		removeOwned(d, uint32(uid))
	}
	if ru := filepath.Join(g.P.RunUser, strconv.Itoa(uid)); fsinfo.DirNoFollow(ru) {
		removeOwned(ru, uint32(uid))
	}
}
