package logs

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"tando/srv/internal/fsinfo"
	"tando/srv/logs/errscan"
	"tando/srv/logs/lines"
)

// history.tsv (written by the agent), one row per deploy, rollback or rolled-back deploy:
//
//	time id kind result total build upload copy preflight switch verify note [release]
//
// (release: the seconds of the release command, only on a deploy that ran one.)
//
// A row's time is when verify ended (whole seconds), so the switch is time - verify, to within a
// second.

// maxHistory bounds what is read of history.tsv (the agent keeps it short; this is a ceiling).
const maxHistory = 16 << 20

func (a *app) history() [][]string {
	f, err := os.Open(filepath.Join(a.dir(), "history.tsv"))
	if err != nil {
		return nil
	}
	defer f.Close()
	var rows [][]string
	r := lines.NewReader(f, 64<<10)
	read := 0
	for {
		ln, ok := r.Next()
		if !ok || read > maxHistory {
			break
		}
		read += ln.Len + 1
		rows = append(rows, strings.Split(string(ln.Text), "\t"))
	}
	return rows
}

func col(r []string, i int) string {
	if i < len(r) {
		return r[i]
	}
	return ""
}

func colNum(r []string, i int) float64 { return lines.Num([]byte(col(r, i))) }

// liveSwitch: the row is a release going live: a deploy or rollback that ended ok, or a deploy
// whose soak a newer deploy cut short (superseded: it was live until the next switch).
func liveSwitch(r []string) bool {
	k, res := col(r, 2), col(r, 3)
	return (res == "ok" && (k == "deploy" || k == "rollback")) || (res == "superseded" && k == "deploy")
}

// releaseRanges: the periods during which release id was current, [from, to) in microseconds
// (whole numbers, as the shell's "%.0f").
func (a *app) releaseRanges(id string, now int64) [][2]float64 {
	type sw struct {
		t  float64
		id string
	}
	var s []sw
	good := ""
	for _, r := range a.history() {
		switch {
		case liveSwitch(r):
			s = append(s, sw{colNum(r, 0) - colNum(r, 10), col(r, 1)})
			if col(r, 3) == "ok" { // (a superseded release is never what a rollback goes back to)
				good = col(r, 1)
			}
		case col(r, 3) == "rolledback":
			s = append(s, sw{colNum(r, 0) - colNum(r, 10), col(r, 1)}, sw{colNum(r, 0), good})
		}
	}
	var out [][2]float64
	for i, x := range s {
		if x.id != id {
			continue
		}
		to := float64(now + 1)
		if i < len(s)-1 {
			to = s[i+1].t
		}
		if to > x.t {
			out = append(out, [2]float64{round0(x.t * 1e6), round0(to * 1e6)})
		}
	}
	return out
}

// round0 is printf "%.0f" (round half to even, as glibc).
func round0(v float64) float64 {
	f, _ := strconv.ParseFloat(strconv.FormatFloat(v, 'f', 0, 64), 64)
	return f
}

// switches: every switch of the live release, oldest first, the last 50.
func (a *app) switches() []errscan.Switch {
	var s []errscan.Switch
	for _, r := range a.history() {
		if liveSwitch(r) {
			s = append(s, errscan.Switch{T: int64(colNum(r, 0) - colNum(r, 10)), ID: col(r, 1)})
		}
	}
	if len(s) > 50 {
		s = s[len(s)-50:]
	}
	return s
}

// liveRelease: the release that went live last, and when (a rollback of a deploy moves the time).
func (a *app) liveRelease() (string, int64) {
	id := ""
	var t float64
	for _, r := range a.history() {
		switch {
		case liveSwitch(r):
			id, t = col(r, 1), colNum(r, 0)-colNum(r, 10)
		case col(r, 3) == "rolledback":
			t = colNum(r, 0)
		}
	}
	return id, int64(t)
}

// knownRelease: the release has a directory or a history row.
func (a *app) knownRelease(id string) bool {
	if fsinfo.DirFollow(filepath.Join(a.dir(), "releases", id)) {
		return true
	}
	b, err := os.ReadFile(filepath.Join(a.dir(), "history.tsv"))
	return err == nil && strings.Contains(string(b), "\t"+id+"\t")
}

// deployHeader: "# deploy <id>: ok (12s: copy 1, pre-flight 3, switch 0, verify 2)" for each
// history row of the release, control characters removed.
func (a *app) deployHeader(id string) []string {
	var out []string
	for _, r := range a.history() {
		if col(r, 1) != id {
			continue
		}
		note := ""
		if n := col(r, 11); n != "" && n != "-" {
			note = " - " + n
		}
		s := "# " + col(r, 2) + " " + col(r, 1) + ": " + col(r, 3) + " (" + col(r, 4) + "s: copy " + col(r, 7) +
			", pre-flight " + col(r, 8) + ", switch " + col(r, 9) + ", verify " + col(r, 10) + ")" + note
		out = append(out, dropControls(s))
	}
	return out
}

// dropControls removes C0 controls but the tab, and DEL (the shell's tr -d '\000-\010\013-\037\177').
func dropControls(s string) string {
	b := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		if c := s[i]; (c >= 0x20 || c == '\t' || c == '\n') && c != 0x7f {
			b = append(b, c)
		}
	}
	return string(b)
}
