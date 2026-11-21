package errscan

import (
	"sort"
	"strconv"
	"strings"

	"tando/srv/logs/lines"
)

// groups.tsv, one error group per line, tab-separated:
//
//	id count first last release kind label fingerprint title hours
//
// hours is "hour:count,..." for the last 7 days. A line with fewer than 10 fields is not a group
// (dropped at the next merge); a line is written back byte for byte unless the group got events.

// MaxGroups per app. Over it, groups are dropped (and their samples) least recently seen first,
// but a group the table had before this scan and saw in the last KeepDays days is dropped only
// after every group first seen in this scan: an app logging hundreds of distinct new messages
// cannot push out the groups already known (and notified), to have a real error reported as new
// again. (The shell version dropped by last seen alone.)
const (
	MaxGroups = 200
	KeepDays  = 7
)

// Switch is a release going live (from history.tsv).
type Switch struct {
	T  int64
	ID string
}

// Table is groups.tsv being merged with one scan's events.
type Table struct {
	Now  int64    // epoch seconds
	Live string   // the live release ("" for none)
	Rels []Switch // the switches of the live release, oldest first
	Base bool     // the first scan of an app: groups are learned, not reported as new
	Max  int      // groups kept; 0: MaxGroups

	groups map[string]*group
	order  []string
}

type group struct {
	raw    string   // as read; "" once fields is set
	fields []string // exactly 10 once the group got an event
	isNew  bool
	fresh  bool // first seen in this scan
	newT   int64
	cnt    int64
	pos    int
}

// Load reads the current groups.tsv (nil or empty: none).
func (t *Table) Load(data []byte) {
	t.groups = map[string]*group{}
	t.order = nil
	for l := range strings.SplitSeq(string(data), "\n") {
		if l == "" || strings.Count(l, "\t") < 9 {
			continue
		}
		id := l[:strings.IndexByte(l, '\t')]
		if g, ok := t.groups[id]; ok {
			g.raw, g.fields = l, nil // a repeated id: the last line, the first place
			continue
		}
		t.groups[id] = &group{raw: l, pos: len(t.order)}
		t.order = append(t.order, id)
	}
}

func (g *group) split() []string {
	if g.fields == nil {
		f := strings.Split(g.raw, "\t")
		g.fields = f[:10:10]
		g.raw = ""
	}
	return g.fields
}

func (g *group) line() string {
	if g.fields == nil {
		return g.raw
	}
	return strings.Join(g.fields, "\t")
}

func field(f []string, i int) string {
	if i < len(f) {
		return f[i]
	}
	return ""
}

// Add merges one event.
func (t *Table) Add(e Event) {
	if t.groups == nil {
		t.groups = map[string]*group{}
	}
	ts := strconv.FormatInt(e.T0, 10)
	g, ok := t.groups[e.ID]
	if !ok {
		g = &group{fields: []string{e.ID, "0", ts, ts, t.releaseAt(e.T0), e.Kind, e.Label, e.Fingerprint, e.Title, ""},
			pos: len(t.order), fresh: true}
		t.groups[e.ID] = g
		t.order = append(t.order, e.ID)
		if !t.Base {
			g.isNew, g.newT = true, e.T0
		}
	}
	f := g.split()
	f[1] = num(lines.Num([]byte(f[1])) + 1)
	t0 := float64(e.T0)
	if less(t0, f[2], true) {
		f[2] = ts
	}
	if less(t0, f[3], false) {
		f[3] = ts
	}
	f[9] = t.addHour(f[9], e.T0/3600*3600)
	g.cnt++
}

// less: t < s (lt) or t > s (!lt) by awk's rules: numerically when s looks like a number, else
// as text.
func less(t float64, s string, lt bool) bool {
	if lines.IsNum(s) {
		v := lines.Num([]byte(s))
		if lt {
			return t < v
		}
		return t > v
	}
	if lt {
		return num(t) < s
	}
	return num(t) > s
}

func num(v float64) string {
	if v == float64(int64(v)) && v > -9e18 && v < 9e18 {
		return strconv.FormatInt(int64(v), 10)
	}
	return strconv.FormatFloat(v, 'g', 6, 64)
}

// releaseAt: the release live at time t, the last switch at or before it (to within a second;
// history times are whole seconds), else the live one, else "-".
func (t *Table) releaseAt(ts int64) string {
	r := ""
	for _, s := range t.Rels {
		if s.T <= ts+1 {
			r = s.ID
		}
	}
	switch {
	case r != "":
		return r
	case t.Live != "":
		return t.Live
	}
	return "-"
}

// addHour counts one event in hour h of "hour:count,...", dropping hours older than 7 days.
func (t *Table) addHour(s string, h int64) string {
	h0 := t.Now/3600*3600 - 167*3600
	var b strings.Builder
	done := false
	if s != "" {
		for p := range strings.SplitSeq(s, ",") {
			q1, q2, _ := strings.Cut(p, ":")
			q2, _, _ = strings.Cut(q2, ":")
			v := lines.Num([]byte(q1))
			if v < float64(h0) {
				continue
			}
			if v == float64(h) {
				q2 = num(lines.Num([]byte(q2)) + 1)
				done = true
			}
			if b.Len() > 0 {
				b.WriteByte(',')
			}
			b.WriteString(q1 + ":" + q2)
		}
	}
	if !done {
		if b.Len() > 0 {
			b.WriteByte(',')
		}
		b.WriteString(strconv.FormatInt(h, 10) + ":1")
	}
	return b.String()
}

// NewGroup is a group seen for the first time in this scan.
type NewGroup struct {
	ID          string
	T, N        int64
	Kind, Label string
}

// Count is how many events a group got in this scan.
type Count struct {
	ID    string
	N     int64
	Label string
}

// Result is the merged table and what changed.
type Result struct {
	Data    []byte     // the new groups.tsv
	Dropped []string   // ids beyond MaxGroups (their samples go)
	New     []NewGroup // in the order they were first seen
	Counts  []Count
}

// Result sorts the groups, newest last-seen first, and keeps MaxGroups.
func (t *Table) Result() Result {
	type key struct {
		v  float64
		id string
	}
	keys := make([]key, 0, len(t.order))
	for _, id := range t.order {
		f := t.groups[id].split4()
		// awk sorted on (last "\t" id) + 0: the number the line's 4th field starts with
		keys = append(keys, key{lines.Num([]byte(f + "\t" + id)), id})
	}
	sort.SliceStable(keys, func(i, j int) bool { return keys[i].v > keys[j].v })
	var r Result
	var b strings.Builder
	keep := map[string]bool{}
	limit := t.Max
	if limit == 0 {
		limit = MaxGroups
	}
	if len(keys) > limit {
		// known groups seen lately first, then the rest, each by last seen
		n := 0
		for pass := range 2 {
			for _, k := range keys {
				known := !t.groups[k.id].fresh && k.v >= float64(t.Now-KeepDays*86400)
				if n < limit && !keep[k.id] && (pass == 1 || known) {
					keep[k.id] = true
					n++
				}
			}
		}
	}
	for _, k := range keys {
		if len(keys) > limit && !keep[k.id] {
			r.Dropped = append(r.Dropped, k.id)
			continue
		}
		keep[k.id] = true
		b.WriteString(t.groups[k.id].line())
		b.WriteByte('\n')
	}
	r.Data = []byte(b.String())
	for _, id := range t.order {
		g := t.groups[id]
		if !keep[id] {
			continue
		}
		f := g.fieldsOrSplit()
		if g.isNew {
			r.New = append(r.New, NewGroup{ID: id, T: g.newT, N: g.cnt, Kind: field(f, 5), Label: field(f, 6)})
		}
		if g.cnt > 0 {
			r.Counts = append(r.Counts, Count{ID: id, N: g.cnt, Label: field(f, 6)})
		}
	}
	return r
}

// split4: the 4th field (last seen) without splitting a line that is written back as is.
func (g *group) split4() string {
	if g.fields != nil {
		return g.fields[3]
	}
	return field(strings.SplitN(g.raw, "\t", 5), 3)
}

func (g *group) fieldsOrSplit() []string {
	if g.fields != nil {
		return g.fields
	}
	return strings.Split(g.raw, "\t")
}

// Window is the errors view of groups.tsv: the groups last seen at or after from, newest first,
// at most n, each as
//
//	id  count-in-window  count  first  last  release  kind  label  title
//
// The count in the window is from the hourly counts (whole hours, so an hour that began before
// from counts whole), at least 1.
func Window(data []byte, from int64, n int) [][]string {
	type row struct {
		v float64
		f []string
	}
	var rows []row
	for l := range strings.SplitSeq(strings.TrimSuffix(string(data), "\n"), "\n") {
		f := strings.Split(l, "\t")
		if l == "" {
			f = nil
		}
		if lessStr(field(f, 3), from) {
			continue
		}
		var c float64
		if h := field(f, 9); h != "" {
			for p := range strings.SplitSeq(h, ",") {
				q1, q2, _ := strings.Cut(p, ":")
				q2, _, _ = strings.Cut(q2, ":")
				if lines.Num([]byte(q1))+3600 > float64(from) {
					c += lines.Num([]byte(q2))
				}
			}
		}
		if c == 0 {
			c = 1
		}
		out := []string{field(f, 0), num(c), field(f, 1), field(f, 2), field(f, 3), field(f, 4), field(f, 5),
			field(f, 6), field(f, 8)}
		rows = append(rows, row{lines.Num([]byte(field(f, 3) + "\t" + strings.Join(out, "\t"))), out})
	}
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].v > rows[j].v })
	var res [][]string
	for i := 0; i < len(rows) && i < n; i++ {
		res = append(res, rows[i].f)
	}
	return res
}

// lessStr: field < from by awk's rules.
func lessStr(s string, from int64) bool {
	if lines.IsNum(s) {
		return lines.Num([]byte(s)) < float64(from)
	}
	return s < strconv.FormatInt(from, 10)
}

// Hours is each group's hourly counts that fall in a window starting at from (the hour holding
// from included, as Window counts them), by group id: "hour:count,..." with the hour's start in
// epoch seconds, oldest first, only hours that had errors. For tando errors --json's series.
func Hours(data []byte, from int64) map[string]string {
	res := map[string]string{}
	for l := range strings.SplitSeq(strings.TrimSuffix(string(data), "\n"), "\n") {
		if l == "" {
			continue
		}
		f := strings.Split(l, "\t")
		var b strings.Builder
		for p := range strings.SplitSeq(field(f, 9), ",") {
			q1, q2, _ := strings.Cut(p, ":")
			q2, _, _ = strings.Cut(q2, ":")
			h, err1 := strconv.ParseInt(q1, 10, 64)
			c, err2 := strconv.ParseInt(q2, 10, 64)
			if err1 != nil || err2 != nil || h < 0 || c <= 0 || h+3600 <= from {
				continue
			}
			if b.Len() > 0 {
				b.WriteByte(',')
			}
			b.WriteString(strconv.FormatInt(h, 10) + ":" + strconv.FormatInt(c, 10))
		}
		if id := field(f, 0); id != "" {
			res[id] = b.String()
		}
	}
	return res
}
