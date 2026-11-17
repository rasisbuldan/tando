package watch

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"tando/srv/internal/bashread"
	"tando/srv/internal/valid"
)

var epochRe = regexp.MustCompile(`^[0-9]{9,11}$`)

// readInbox turns the agent's notices (and tandod's about itself: "monitor\thost\ttandod\t<text>") ($V/inbox, root 700, one file each, named
// <epoch>.<app>.<release>: kind TAB app TAB release TAB text), such as a release rolled back after
// its deploy had returned, into events, each sent once: the file is deleted when the run commits
// (commit.go). A notice older than an hour is history, not news (alerts set up later, the timer
// off while it waited): dropped unsent; tando history keeps the rollback.
func (t *tick) readInbox() {
	dir := filepath.Join(t.w.Dir, "inbox")
	ents, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	names := make([]string, 0, len(ents))
	for _, e := range ents {
		names = append(names, e.Name())
	}
	sort.Strings(names)
	for _, n := range names {
		f := filepath.Join(dir, n)
		fi, err := os.Lstat(f)
		if strings.HasPrefix(n, ".") || err != nil || !fi.Mode().IsRegular() || strings.HasSuffix(n, ".tmp") {
			continue
		}
		ts, _, _ := strings.Cut(n, ".")
		if epochRe.MatchString(ts) && t.now-num(ts, 0) > 3600 {
			os.Remove(f)
			continue
		}
		b, _ := os.ReadFile(f)
		first, _, _ := strings.Cut(string(b), "\n")
		p := bashread.Fields(first, 4) // kind app release text (the release id is also in the text)
		switch {
		case p[0] == "rollback" && valid.App(p[1]):
			t.inbox = append(t.inbox, f)
			t.event("rollback", p[1], "deploy", p[3])
		case p[0] == "monitor" && p[1] == "host": // tandod about itself (srv/daemon health.go)
			t.inbox = append(t.inbox, f)
			t.event("monitor", "_host", "tandod", p[3])
		default:
			os.Remove(f) // not a notice of ours: nothing to send
		}
	}
}
