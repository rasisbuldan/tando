package status

import (
	"bytes"
	"context"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"tando/srv/internal/decimal"
	"tando/srv/internal/valid"
)

// Releases is the verb `releases <app>`: one row per release, newest first, then an origin row
// (app.conf's origin) when the app has one.
func (c *Collector) Releases(ctx context.Context, w io.Writer, name string) error {
	a, err := c.selectApp(name)
	if err != nil {
		return err
	}
	s := newSink()
	for _, r := range ReleaseRows(a.state, c.releaseIDs(a.dir)) {
		s.row(r...)
	}
	// did the release command change the schema: "mig <id> yes|no|? <pre-release backup id or ->",
	// for the releases that have a record (cmd_releases_verb)
	for _, id := range reverse(bySeq(a.state, c.releaseIDs(a.dir))) {
		if m := a.state.get("migrated_" + id); m != "" {
			s.row("mig", id, m, a.state.get("prerelease_"+id))
		}
	}
	// where it was last deployed from (user@machine:path; tando-dash deploys from that folder)
	if o := a.conf.get("origin"); o != "" {
		s.row("origin", o)
	}
	return s.to(w)
}

func reverse(ids []string) []string {
	r := make([]string, len(ids))
	for i, id := range ids {
		r[len(ids)-1-i] = id
	}
	return r
}

// migRows are the history verb's "mig <app> <id> yes|no|? <backup id or ->" rows of an app: the
// releases with a schema record in its state, in the order of their ids (as the agent's sort).
func migRows(s *sink, name string, st kv) {
	var ids []string
	for k, v := range st.m {
		if strings.HasPrefix(k, "migrated_") && len(k) > 9 && k[9] >= '0' && k[9] <= '9' && v != "" {
			ids = append(ids, strings.TrimPrefix(k, "migrated_"))
		}
	}
	sort.Strings(ids)
	for _, id := range ids {
		s.row("mig", name, id, st.get("migrated_"+id), st.get("prerelease_"+id))
	}
}

// releaseIDs are the names in releases/ that are release ids (`for i in "$D"/releases/*;
// valid_id "$i"`), in any order.
func (c *Collector) releaseIDs(dir string) []string {
	ents, err := os.ReadDir(filepath.Join(dir, "releases"))
	if err != nil {
		return nil
	}
	var ids []string
	for _, e := range ents {
		if valid.ID(e.Name()) {
			ids = append(ids, e.Name())
		}
	}
	return ids
}

// ReleaseRows is cmd_releases: `row rel "$i" "${S[status_$i]:-pending}" "$cur" "$last"` for each
// release of releases_by_seq, newest first (`| tac`).
func ReleaseRows(S kv, ids []string) [][]string {
	ordered := bySeq(S, ids)
	rows := make([][]string, 0, len(ordered))
	for i := len(ordered) - 1; i >= 0; i-- {
		id := ordered[i]
		cur, last := "0", "0"
		if id == S.get("current") {
			cur = "1"
		}
		if id == S.get("last_good") {
			last = "1"
		}
		row := []string{"rel", id, S.or("status_"+id, "pending"), cur, last}
		// a 6th field, the git provenance "sha:changed files:branch", only for a release that has one
		if g := S.get("git_" + id); g != "" {
			row = append(row, g)
		}
		rows = append(rows, row)
	}
	return rows
}

// bySeq is releases_by_seq: oldest first, in the order the releases were deployed (S[seq_<id>],
// given at activate; the clock does not matter); releases without a number sort first, by name.
// The shell piped "<seq> <id>" lines through `sort -k1,1n -k2,2`: a number as sort -n reads it
// (leading blanks, a sign, digits, a fraction; anything else counts as 0), then the id.
func bySeq(S kv, ids []string) []string {
	type rel struct {
		seq string
		id  string
	}
	rs := make([]rel, len(ids))
	for i, id := range ids {
		rs[i] = rel{S.or("seq_"+id, "0"), id}
	}
	sort.SliceStable(rs, func(i, j int) bool {
		if c := numCompare(rs[i].seq, rs[j].seq); c != 0 {
			return c < 0
		}
		return rs[i].id < rs[j].id
	})
	res := make([]string, len(rs))
	for i, r := range rs {
		res[i] = r.id
	}
	return res
}

// numCompare compares two strings as GNU sort -n does in the C locale: the longest prefix of
// optional blanks, an optional "-", digits and an optional "." with digits; no number is 0.
func numCompare(a, b string) int {
	na, fa, nega := numParts(a)
	nb, fb, negb := numParts(b)
	zero := func(n, f string) bool { return n == "" && strings.Trim(f, "0") == "" }
	if zero(na, fa) {
		nega = false
	}
	if zero(nb, fb) {
		negb = false
	}
	if nega != negb {
		if nega {
			return -1
		}
		return 1
	}
	c := absCompare(na, fa, nb, fb)
	if nega {
		return -c
	}
	return c
}

// numParts: the integer digits without leading zeros, the fraction digits, and the sign.
func numParts(s string) (string, string, bool) {
	s = strings.TrimLeft(s, " \t")
	neg := false
	if strings.HasPrefix(s, "-") {
		neg, s = true, s[1:]
	}
	i := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		i++
	}
	n := strings.TrimLeft(s[:i], "0")
	f := ""
	if i < len(s) && s[i] == '.' {
		j := i + 1
		for j < len(s) && s[j] >= '0' && s[j] <= '9' {
			j++
		}
		f = s[i+1 : j]
	}
	return n, f, neg
}

func absCompare(na, fa, nb, fb string) int {
	if len(na) != len(nb) {
		if len(na) < len(nb) {
			return -1
		}
		return 1
	}
	if c := strings.Compare(na, nb); c != 0 {
		return c
	}
	fa, fb = strings.TrimRight(fa, "0"), strings.TrimRight(fb, "0")
	return strings.Compare(fa, fb)
}

// History is the verb `history [app] [n]`: the last n (default 20) lines of each app's
// history.tsv that have the 12 fields of a deploy record (13 with a release command's seconds), as `hist <app> <fields...>` rows.
// Without an app every directory under apps/ with a history.tsv counts.
func (c *Collector) History(ctx context.Context, w io.Writer, name, count string) error {
	n := int64(20)
	// a lone number is the count (app names start with a letter): `history 20` as the CLI sends
	// it for all apps
	if count == "" && decimal.IsDigits(name) {
		name, count = "", name
	}
	if count != "" {
		if !decimal.IsDigits(count) {
			return die("bad count")
		}
		n = histCount(count)
	}
	if name != "" && !valid.App(name) {
		return die("invalid app name")
	}
	s := newSink()
	if name != "" {
		c.history(s, name, n)
	} else {
		ents, _ := os.ReadDir(filepath.Join(c.Env.Root, "apps"))
		for _, e := range ents { // (os.ReadDir sorts by name: the glob's order in C.UTF-8)
			if valid.App(e.Name()) {
				c.history(s, e.Name(), n)
			}
		}
	}
	return s.to(w)
}

// histCount reads the count of tail -n; a number too long for int64 means all lines.
func histCount(s string) int64 {
	s = strings.TrimLeft(s, "0")
	if len(s) > 18 {
		return 1 << 62
	}
	return int64(uatoi(s))
}

// maxHistTail bounds how much of the end of a history file is read for its last n lines.
const maxHistTail = 16 << 20

// history adds `tail -n "$n" history.tsv | awk -F '\t' 'NF >= 12 && NF <= 14' | sed "s/^/hist\t$app\t/"`.
// Each field is cleaned again (they were written cleaned by the agent's row).
func (c *Collector) history(s *sink, name string, n int64) {
	hf := filepath.Join(c.appDir(name), "history.tsv")
	if f, err := os.Open(hf); err != nil { // (the shell: [[ -r history.tsv ]] || continue)
		return
	} else {
		f.Close()
	}
	if n <= 0 {
		migRows(s, name, loadKV(filepath.Join(c.appDir(name), "state")))
		return
	}
	for _, l := range tailLines(hf, n, maxHistTail) {
		if n := strings.Count(l, "\t"); n < 11 || n > 13 { // (12: with the release command's seconds; 13: and the git provenance)
			continue
		}
		// (not s.row: an empty field stays empty, as awk printed it)
		s.fields(append([]string{"hist", name}, strings.Split(l, "\t")...)...)
	}
	migRows(s, name, loadKV(filepath.Join(c.appDir(name), "state")))
}

// tailLines is tail -n n: the last n lines of the file (a last line without a newline counts),
// read backwards from the end in blocks, at most max bytes.
func tailLines(path string, n int64, max int64) []string {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil || !fi.Mode().IsRegular() {
		return nil
	}
	size := fi.Size()
	const block = 16 << 10
	var buf []byte
	pos := size
	for pos > 0 && size-pos < max {
		step := int64(block)
		if pos < step {
			step = pos
		}
		pos -= step
		chunk := make([]byte, step)
		if _, err := f.ReadAt(chunk, pos); err != nil && err != io.EOF {
			return nil
		}
		buf = append(chunk, buf...)
		// enough newlines for n lines (the file's last newline ends the last line)
		nl := int64(bytes.Count(buf, []byte{'\n'}))
		if len(buf) > 0 && buf[len(buf)-1] == '\n' {
			nl--
		}
		if nl >= n {
			break
		}
	}
	if len(buf) > 0 && buf[len(buf)-1] == '\n' {
		buf = buf[:len(buf)-1]
	} else if len(buf) == 0 {
		return nil
	}
	all := strings.Split(string(buf), "\n")
	if pos > 0 && len(all) > 0 { // the first piece may be the end of an earlier line
		all = all[1:]
	}
	if int64(len(all)) > n {
		all = all[int64(len(all))-n:]
	}
	return all
}
