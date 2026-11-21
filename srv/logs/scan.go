package logs

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	"tando/srv/internal/atomicfile"
	"tando/srv/internal/decimal"
	"tando/srv/internal/fsinfo"
	"tando/srv/internal/lock"
	"tando/srv/internal/out"
	"tando/srv/internal/valid"
	"tando/srv/logs/errscan"
	"tando/srv/logs/lines"
	"tando/srv/logs/reqlog"
)

// The error and request scan: incremental, once a minute (tando-watch) and for tando errors.
//
// Per app in Lib/logscan/<app>/ (root 700): the journal cursor (cursor), the request log
// position ("<inode> <bytes>", req), the error groups (groups.tsv, at most errscan.MaxGroups) and
// one sample per group (samples/<id>, at most 30 lines of 240 characters), all 644. A scan reads
// only what was written since the last one, at most scanLines journal entries and scanBytes of
// request log (beyond that the oldest part is skipped and counted), so its cost follows the log
// rate and has a ceiling.
const (
	scanLines = 20000
	scanBytes = 8 << 20
	scanLock  = 20 * time.Second
)

// WatchScan (watch-scan [app...]): every app with a release when none is named (static sites:
// only their request log). Rows per app, for tando-watch:
//
//	newerr <app> <id> <first ts> <count> <kind> <label>   a group seen for the first time
//	errtop <app> <count> <label [id]>                     the group with most events this scan
//	release <app> <id> <live since>
//	top <app> <count> <status> <method path>              up to 3 failing paths
//	scan <app> <journal lines read> <error events> <suppressed> <requests> <5xx> <p95 ms> <bytes skipped>
func (l *Logs) WatchScan(ctx context.Context, names []string, w *out.Writer) error {
	if err := l.needRoot(); err != nil {
		return err
	}
	c := l.Cache
	if c == nil {
		c = NewScanCache()
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(names) == 0 {
		names = c.liveApps(l)
	}
	for _, n := range names {
		if !valid.App(n) {
			l.warn("tando-logs: invalid app name")
			continue
		}
		as := c.app(l, n)
		// nothing written to the app's journal or request log since its last full scan (the same
		// inodes, sizes and times): the row that scan would print, without opening anything
		sigs := c.signatures(as)
		if as.idle && sigs == as.sigs && (sigs[2].ok || !sigs[0].ok) { // (a namespace without a journal file yet: ask journalctl)
			w.Row("scan", n, "0", "0", "0", "0", "0", "0", "0")
			continue
		}
		as.idle = false
		a, err := l.app(n)
		if err != nil {
			l.warn("tando-logs: %v", err)
			continue
		}
		a.sc, a.as = c, as
		if a.scan(ctx, w, sigs) {
			as.idle, as.sigs = true, sigs
		}
	}
	return nil
}

// liveApps: the apps whose state names a current release (a line "current=<something>").
func (l *Logs) liveApps() []string {
	ents, _ := os.ReadDir(filepath.Join(l.Env.Root, "apps"))
	var names []string
	for _, e := range ents {
		b, err := os.ReadFile(filepath.Join(l.Env.Root, "apps", e.Name(), "state"))
		if err != nil {
			continue
		}
		for line := range strings.SplitSeq(string(b), "\n") {
			if len(line) > len("current=") && strings.HasPrefix(line, "current=") {
				names = append(names, e.Name())
				break
			}
		}
	}
	return names
}

var reCursor = regexp.MustCompile(`^[A-Za-z0-9=;_-]+$`)

func (a *app) scanDir() string { return filepath.Join(a.l.scanDir(), a.name) }

// scan one app: its journal since the cursor, its request log since the position; true when it
// ran to the end (then sigs, taken before it, describe what it has read).
func (a *app) scan(ctx context.Context, w *out.Writer, sigs [6]fsig) bool {
	d := a.scanDir()
	if !fsinfo.DirFollow(filepath.Join(d, "samples")) {
		for _, p := range []string{a.l.scanDir(), d, filepath.Join(d, "samples")} {
			if err := ensureDir(p, 0o700, -1, -1); err != nil {
				a.l.warn("tando-logs: %v", err)
				return false
			}
		}
	}
	lk, err := lock.Acquire(filepath.Join(d, "lock"), scanLock)
	if err != nil {
		return false
	}
	defer lk.Release()
	var nread, nev, sup int64
	if sigs[0].ok || sigs[2].ok { // the app logs into its own journal
		nread, nev, sup = a.scanJournal(ctx, w, sigs)
	}
	tot, e5, p95, skip := a.scanRequests(ctx, w)
	w.Row("scan", a.name, decimal.Itoa(nread), decimal.Itoa(nev), decimal.Itoa(sup), decimal.Itoa(tot), decimal.Itoa(e5), decimal.Itoa(p95), decimal.Itoa(skip))
	return ctx.Err() == nil
}

// firstLineOf: the first line of a small file, trimmed (bash's read -r x < f).
func firstLineOf(p string) string {
	f, err := os.Open(p)
	if err != nil {
		return ""
	}
	defer f.Close()
	var buf [512]byte
	b := buf[:]
	n, _ := io.ReadFull(f, b)
	s, _, _ := strings.Cut(string(b[:n]), "\n")
	return strings.TrimSpace(s)
}

// scanJournal runs the app's journal lines since the last scan through the error scanner and
// commits what it found: the groups table (groups.tsv, with the cursor it covers), a sample per
// new group, the cursor, and the rows newerr, errtop and release. It returns the lines read, the
// error events (0 on a first scan, which learns) and the suppressed lines.
func (a *app) scanJournal(ctx context.Context, w *out.Writer, sigs [6]fsig) (nread, nev, sup int64) {
	d := a.scanDir()
	j := a.readJournal(ctx, sigs)
	if j.unchanged {
		return 0, 0, 0
	}
	if j.badCursor {
		// journalctl refused the cursor (rotated away, damaged): from now on, said, not silent
		w.Row("warn", a.name, "journal cursor not found: reading from now on")
		a.l.warn("tando-logs: %s: journal cursor not found: reading from now on", a.name)
		writeCursor(d, "s "+decimal.Itoa(j.start))
		return 0, 0, 0
	}
	s := j.scanner
	if s.Events > 0 || j.gerr != nil {
		r := j.table.Result()
		// the cursor these counts reach goes with them, in the same atomic write: a crash between
		// this and the cursor file cannot make the next scan count the same lines again
		data := r.Data
		if s.Cursor != "" {
			data = append(append(data[:len(data):len(data)], "cursor\t"...), s.Cursor+"\n"...)
		}
		atomicfile.Write(filepath.Join(d, "groups.tsv"), data, atomicfile.Mode(0o644))
		saveSamples(filepath.Join(d, "samples"), r.Dropped, j.samples, j.order)
		scanRows(w, a.name, r, j.base, j.live, j.liveT)
	}
	switch {
	case s.Cursor != "":
		writeCursor(d, "c "+s.Cursor)
	case j.cursor == "":
		writeCursor(d, "s "+decimal.Itoa(j.start)) // (nothing logged yet: read from this scan's time)
	}
	writeInPlace(filepath.Join(d, "jstamp"), []byte(j.stamp+"\n"), 0o644)
	if j.base {
		return s.Read, 0, s.Suppressed // a first scan learns: its events are not this minute's
	}
	return s.Read, s.Events, s.Suppressed
}

// journalRead is what reading the journal since the monitor's position gave, not committed.
type journalRead struct {
	unchanged, badCursor bool // the journal files did not change (nothing read); journalctl refused the cursor
	base                 bool // a first scan: learn, report nothing
	cursor               string
	start                int64
	stamp                string
	table                *errscan.Table
	scanner              *errscan.Scanner
	samples              map[string][]string
	order                []string
	gerr                 error
	live                 string
	liveT                int64
}

// readJournal reads the app's journal lines since the monitor's position (the cursor, else the
// time of the first scan that found nothing) into the groups table in memory. It writes nothing:
// tando errors shows this without taking the monitor's events from it.
func (a *app) readJournal(ctx context.Context, sigs [6]fsig) *journalRead {
	d := a.scanDir()
	groups := filepath.Join(d, "groups.tsv")
	old, gerr := readCapped(groups, 16<<20)
	cur, since := scanPosition(d, old)
	arg, base := "--since=-24h", true
	switch {
	case cur != "":
		arg, base = "--after-cursor="+cur, false
	case since != "":
		arg, base = "--since=@"+since, false
	}
	j := &journalRead{base: base, cursor: cur, start: a.l.Env.Now().Unix(), gerr: gerr, samples: map[string][]string{}}
	// Nothing written to the namespace since the last scan (the same active file: inode, size,
	// times): journalctl would print nothing, so it is not started. journald truncates its file to
	// its own size after each write batch, to fire inotify, which also moves its mtime.
	j.stamp = fmt.Sprintf("%v %d %d %d", sigs[2].ok, sigs[2].ino, sigs[2].size, sigs[2].mtime)
	if sigs[2].ok && !base && firstLineOf(filepath.Join(d, "jstamp")) == j.stamp && gerr == nil {
		j.unchanged = true
		return j
	}
	j.live, j.liveT = a.liveRelease()
	j.table = &errscan.Table{Now: j.start, Live: j.live, Rels: a.switches(), Base: base}
	j.table.Load(old)
	j.scanner = &errscan.Scanner{Emit: func(e errscan.Event) {
		j.table.Add(e)
		if e.Sample != nil {
			if _, ok := j.samples[e.ID]; !ok {
				j.order = append(j.order, e.ID)
			}
			j.samples[e.ID] = e.Sample
		}
	}}
	jc := []string{"journalctl", "--no-pager", "-q", "-o", "short-unix", "--show-cursor", "--namespace=" + a.ns(),
		"-u", "tando-" + a.name + ".service", "-u", "systemd-journald@" + a.ns() + ".service", "-n", strconv.Itoa(scanLines), arg}
	err := a.l.stream(ctx, jc, 50*time.Second, errscan.MaxMessage+1024, func(ln lines.Line) bool {
		j.scanner.Line(ln.Text)
		return true
	})
	j.scanner.End()
	if err != nil && cur != "" && j.scanner.Read == 0 && j.scanner.Cursor == "" {
		j.badCursor = true
	}
	return j
}

// The cursor file holds, sealed (a torn write is seen as torn): "c <journal cursor>" after the
// last line read, or "s <epoch>" when the journal had nothing (or the cursor was refused): read
// from that time. groups.tsv carries the cursor its counts reach ("cursor<TAB><c>", a line the
// table and the shell's readers skip); of the two the further one is where to go on.
func writeCursor(d, v string) {
	writeInPlace(filepath.Join(d, "cursor"), []byte(sealed(v+"\n")), 0o644)
}

// scanPosition: the cursor to read after, else the time to read from; both empty for a first
// scan (no position at all, or none that can be trusted).
func scanPosition(d string, groups []byte) (cursor, since string) {
	raw, _ := os.ReadFile(filepath.Join(d, "cursor"))
	if text, whole := unseal(raw); whole {
		k, v, _ := strings.Cut(strings.TrimSuffix(text, "\n"), " ")
		switch {
		case k == "c" && reCursor.MatchString(v):
			cursor = v
		case k == "s" && decimal.IsDigits(v):
			since = v
		}
	} else if l := strings.TrimSuffix(string(raw), "\n"); reCursor.MatchString(l) && strings.Contains(l, "i=") {
		cursor = l // (written by the shell version or tando-logs before the seal: one line, whole)
	} else if b, _ := os.ReadFile(filepath.Join(d, "jsince")); decimal.IsDigits(strings.TrimSpace(string(b))) {
		since = strings.TrimSpace(string(b)) // (before the seal)
	}
	if g := groupsCursor(groups); g != "" && (cursor == "" || cursorTime(g) > cursorTime(cursor)) {
		if since == "" || cursorTime(g) >= mustInt(since)*1e6 {
			cursor, since = g, ""
		}
	}
	return cursor, since
}

func groupsCursor(groups []byte) string {
	for l := range strings.SplitSeq(string(groups), "\n") {
		if v, ok := strings.CutPrefix(l, "cursor\t"); ok && reCursor.MatchString(v) {
			return v
		}
	}
	return ""
}

// cursorTime: the realtime (microseconds) a journal cursor names (its t= field), 0 when none.
func cursorTime(c string) int64 {
	for f := range strings.SplitSeq(c, ";") {
		if v, ok := strings.CutPrefix(f, "t="); ok {
			n, err := strconv.ParseInt(v, 16, 64)
			if err == nil {
				return n
			}
		}
	}
	return 0
}

func mustInt(s string) int64 { n, _ := strconv.ParseInt(s, 10, 64); return n }

// saveSamples writes the first event's lines of each group without a sample into dir; dropped
// groups lose theirs.
func saveSamples(dir string, dropped []string, samples map[string][]string, order []string) {
	gone := map[string]bool{}
	for _, id := range dropped {
		gone[id] = true
	}
	for _, id := range order {
		p := filepath.Join(dir, id)
		if gone[id] || !reGroupID.MatchString(id) {
			continue
		}
		if fi, err := os.Lstat(p); err == nil && fi.Size() > 0 {
			continue
		}
		atomicfile.Write(p, []byte(strings.Join(samples[id], "\n")+"\n"), atomicfile.Mode(0o644))
	}
	for _, id := range dropped {
		if reGroupID.MatchString(id) {
			os.Remove(filepath.Join(dir, id))
		}
	}
}

// scanRows are the rows of a scan that saw events: each new group, the most frequent group of
// the window (not on the first scan), the live release.
func scanRows(w *out.Writer, name string, r errscan.Result, base bool, live string, liveT int64) {
	for _, g := range r.New {
		w.Row("newerr", name, g.ID, decimal.Itoa(g.T), decimal.Itoa(g.N), g.Kind, g.Label)
	}
	var top errscan.Count
	for _, c := range r.Counts {
		if c.N > top.N {
			top = c
		}
	}
	if top.N > 0 && !base {
		w.Row("errtop", name, decimal.Itoa(top.N), top.Label+" ["+top.ID+"]")
	}
	if live != "" {
		w.Row("release", name, live, decimal.Itoa(liveT))
	}
}

var reGroupID = regexp.MustCompile(`^[0-9a-f]{8}$`)

// readCapped reads a file of ours up to max bytes; a missing file is an error (it decides
// whether the first groups.tsv is written).
func readCapped(p string, max int64) ([]byte, error) {
	f, err := os.Open(p)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return io.ReadAll(io.LimitReader(f, max))
}

// scanRequests: the requests written since the last scan, from the request index (rollIndex
// reads the log once for everything: this, req-summary, req-errors). The scan keeps its own
// position, Lib/logscan/<app>/req.idx: for each log file, by the hash of its first line (which it
// keeps when Caddy rolls and gzips it), the bytes of it already counted. Records carry their
// line's offset, so the position means the same whatever happens to the index (rebuilt after a
// crash, segments renumbered): a request is counted once. Where the scan cannot tell what it has
// counted (no position, a torn one, two files with the same first line, a file shorter than its
// position) it learns where things are and counts nothing: a burst is never invented. A file it
// does not know is new since the last scan, and counted whole. Only requests of the last
// posMaxAge count at all (a record has its time): after a long stop of the monitor, what was
// logged meanwhile is not reported as this minute's. When the
// index cannot be used (busy beyond its lock's wait, a write error), the log itself, as before.
func (a *app) scanRequests(ctx context.Context, w *out.Writer) (tot, e5, p95, skip int64) {
	if !fsinfo.RegularNoFollow(filepath.Join(a.logDir(), "access.log")) {
		return
	}
	if _, err := a.rollIndex(ctx); err != nil {
		return a.scanRequestsRaw(w)
	}
	sc, as := a.cached()
	x := as.idx
	if x == nil {
		return a.scanRequestsRaw(w)
	}
	now := a.l.Env.Now().Unix()
	pos := filepath.Join(a.scanDir(), "req.idx")
	prev, first := as.pos, false
	if psig := sc.st.stat(cpath(pos)); !psig.ok || psig != as.posSig || prev == nil {
		raw, _ := os.ReadFile(pos)
		prev, first = parsePos(raw)
		as.posBytes = string(raw)
	}
	fps := map[string]int{}
	for _, s := range x.segs {
		fps[s.FP]++
	}
	cur := map[string]int64{}
	var c reqlog.Chunk
	for _, s := range x.segs {
		a.downgradePos(s)
		if s.FP == "-" {
			continue // no whole first line yet: nothing indexed
		}
		cur[s.FP] = s.Off
		p, known := prev[s.FP]
		if known && p > s.Off && !first && s.file != nil && s.file.size >= p {
			cur[s.FP] = p // the index is behind the position (rebuilt, read on over a few rolls): wait for it
			continue
		}
		if first || fps[s.FP] > 1 || known && p > s.Off {
			continue // cannot tell (or the file is shorter than its position: not the same file): learn
		}
		from := int64(0)
		if r, ok := as.posRec[s.FP]; known && ok && r[0] == p && r[1] <= s.Recs {
			from = r[1] // (the last scan's end: no search)
		} else if known {
			from = recordAt(x.path(s, ".rec"), s.Recs, p)
		}
		a.countRecords(x, s, from, float64(now-posMaxAge), &c)
	}
	var b strings.Builder
	b.WriteString(posVersion + "\n")
	for _, s := range x.segs {
		if s.FP != "-" && fps[s.FP] == 1 {
			fmt.Fprintf(&b, "%s %d\n", s.FP, cur[s.FP])
		}
	}
	if nb := sealed(b.String()); nb != as.posBytes || first {
		writeInPlace(pos, []byte(nb), 0o644)
		as.posBytes, as.posSig = nb, sc.st.stat(cpath(pos))
	}
	as.pos = cur
	clear(as.posRec)
	if as.posRec == nil {
		as.posRec = map[string][2]int64{}
	}
	for _, s := range x.segs {
		if s.FP != "-" && cur[s.FP] == s.Off {
			as.posRec[s.FP] = [2]int64{s.Off, s.Recs}
		}
	}
	for _, t := range c.Tops(3) {
		w.Row("top", a.name, decimal.Itoa(t.N), string(reqlog.AppendNum(nil, t.Status)), t.Key)
	}
	return c.Total, c.E5, c.P95(), 0
}

const (
	posVersion = "tando-reqpos 2"
	posMaxAge  = 600 // seconds: requests older than this are not counted as this scan's
)

// parsePos reads req.idx; first (learn, count nothing) when it is missing, torn, or from before
// this format.
func parsePos(raw []byte) (map[string]int64, bool) {
	pos := map[string]int64{}
	b, whole := unseal(raw)
	ls := strings.Split(strings.TrimSuffix(b, "\n"), "\n")
	if !whole || len(ls) == 0 || ls[0] != posVersion || len(ls) > maxLogFiles+2 {
		return pos, true
	}
	for _, l := range ls[1:] {
		fp, off, ok := strings.Cut(l, " ")
		n, err := strconv.ParseInt(off, 10, 64)
		if !ok || err != nil || n < 0 || !reFP.MatchString(fp) {
			return map[string]int64{}, true
		}
		pos[fp] = n
	}
	return pos, false
}

// recordAt: the first of n records of a .rec file whose line starts at or after off (records are
// in the file's order), by binary search; n when none.
func recordAt(p string, n, off int64) int64 {
	f, err := os.Open(p)
	if err != nil {
		return n
	}
	defer f.Close()
	var b [reqlog.RecordSize]byte
	var rec reqlog.Record
	lo, hi := int64(0), n
	for lo < hi {
		mid := (lo + hi) / 2
		if _, err := f.ReadAt(b[:], mid*reqlog.RecordSize); err != nil {
			return n
		}
		rec.Get(b[:])
		if int64(rec.Off) < off {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

// countRecords adds records [from, s.Recs) of a segment logged at or after since to the chunk.
func (a *app) countRecords(x *reqIndex, s *segment, from int64, since float64, c *reqlog.Chunk) {
	var keys *reqlog.Keys
	eachRecord(x.path(s, ".rec"), from, s.Recs, func(r *reqlog.Record) bool {
		if r.Ts < since {
			return true
		}
		c.AddRecord(r, func() string {
			if keys == nil && s.dict != nil && s.dict.Len() == s.Keys {
				keys = &s.dict.Keys
			}
			if keys == nil {
				k, _ := loadKeys(x.path(s, ".path"), s.Dict)
				keys = &k
			}
			if int(r.Path) < keys.Len() {
				return string(keys.Key(r.Path))
			}
			return "- (other paths)"
		})
		return true
	})
}

// downgradePos keeps the shell scan's position file ("<inode> <bytes>") for a downgrade: on a
// roll, and within half its 8 MB cap (that scan never read more than 8 MB behind anyway).
func (a *app) downgradePos(s *segment) {
	as := a.as
	if s.Name != "access.log" || !(s.Ino != as.reqIno || s.Off-as.reqOff > scanBytes/2 || s.Off < as.reqOff) {
		return
	}
	writeInPlace(filepath.Join(a.scanDir(), "req"), []byte(strconv.FormatUint(s.Ino, 10)+" "+decimal.Itoa(s.Off)+"\n"), 0o644)
	as.reqIno, as.reqOff = s.Ino, s.Off
}

// scanRequestsRaw: the request log from the saved position of the current file (a rolled file:
// the new one from its start), at most scanBytes. Exactly the bytes up to the size seen; a last line still being
// written (no newline yet) is left for the next scan.
func (a *app) scanRequestsRaw(w *out.Writer) (tot, e5, p95, skip int64) {
	path := filepath.Join(a.logDir(), "access.log")
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil || !fi.Mode().IsRegular() {
		return
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return
	}
	ino, size := strconv.FormatUint(uint64(st.Ino), 10), fi.Size()
	d := a.scanDir()
	words := strings.Fields(firstLineOf(filepath.Join(d, "req")))
	pino, spos := "", ""
	if len(words) > 0 {
		pino = words[0]
	}
	if len(words) > 1 {
		spos = words[1]
	}
	pos, perr := strconv.ParseInt(spos, 10, 64)
	if pino != ino || perr != nil || !decimal.IsDigits(spos) || pos > size {
		pos = 0
	}
	if pino == "" {
		pos = size // first scan: start at the end
	}
	if size-pos > scanBytes {
		skip = size - pos - scanBytes
		pos = size - scanBytes
	}
	end := size
	if size > pos {
		var c reqlog.Chunk
		p := reqlog.NewParser()
		var r reqlog.Request
		var nb int64
		lr := lines.NewReader(io.NewSectionReader(f, pos, size-pos), reqlog.MaxLine)
		for {
			ln, ok := lr.Next()
			if !ok || !ln.EOL {
				break
			}
			nb += int64(ln.Len) + 1
			if p.Parse(ln.Text, &r) {
				c.Add(&r)
			}
		}
		tot, e5, p95 = c.Total, c.E5, c.P95()
		for _, t := range c.Tops(3) {
			w.Row("top", a.name, decimal.Itoa(t.N), string(reqlog.AppendNum(nil, t.Status)), t.Key)
		}
		end = pos + nb
	}
	if pino != ino || end != pos {
		atomicfile.Write(filepath.Join(d, "req"), []byte(ino+" "+decimal.Itoa(end)+"\n"), atomicfile.Mode(0o644))
	}
	return
}

// Errors (errors <app> <seconds> [n]): scan first, then the groups seen within the window, newest
// first, each with its sample:
//
//	err <id> <count in window> <count total> <first> <last> <release> <kind> <label> <title>
//	hours <id> <hour start:count,...>    the hours of the window that had errors, oldest first
//	sample <id> <line>
func (l *Logs) Errors(ctx context.Context, name, window, count string, w *out.Writer) error {
	if err := l.needRoot(); err != nil {
		return err
	}
	a, err := l.app(name)
	if err != nil {
		return err
	}
	if window == "" {
		window = "86400"
	}
	if count == "" {
		count = "20"
	}
	ws, ok1 := decimal.Parse(window, 8)
	n, ok2 := decimal.Parse(count, 3)
	if !ok1 || !ok2 {
		return errors.New("bad window or count")
	}
	// A view: the groups as the monitor has them, with what was logged since its last scan folded
	// in memory. Nothing is written: the monitor's position, groups and samples stay its own, so
	// what this shows is still reported by it (a newerr, an errors spike) at its next scan.
	sc, as := a.cached()
	d := a.scanDir()
	data, _ := readCapped(filepath.Join(d, "groups.tsv"), 16<<20)
	var fresh map[string][]string
	if sigs := sc.signatures(as); sigs[0].ok || sigs[2].ok {
		if j := a.readJournal(ctx, sigs); !j.unchanged && !j.badCursor && j.scanner.Events > 0 {
			data, fresh = j.table.Result().Data, j.samples
		}
	}
	if len(data) == 0 {
		return nil
	}
	rows := errscan.Window(data, l.Env.Now().Unix()-ws, int(n))
	for _, r := range rows {
		w.Row(append([]string{"err"}, r...)...)
	}
	// each group's errors per hour in the window (hours <id> <hour:count,...>): an older client
	// reads err and sample rows only
	hours := errscan.Hours(data, l.Env.Now().Unix()-ws)
	for _, r := range rows {
		if h := hours[r[0]]; h != "" && reGroupID.MatchString(r[0]) {
			w.Row("hours", r[0], h)
		}
	}
	for _, r := range rows {
		id := r[0]
		if !reGroupID.MatchString(id) {
			continue
		}
		sample := fresh[id]
		if sample == nil {
			b, err := readCapped(filepath.Join(d, "samples", id), 64<<10)
			if err != nil {
				continue
			}
			sample = strings.Split(strings.TrimSuffix(string(b), "\n"), "\n")
		}
		for _, line := range sample {
			if line == "" {
				line = " " // a blank line of a trace stays blank (an empty field would read "-")
			}
			w.Row("sample", id, line)
		}
	}
	return nil
}
