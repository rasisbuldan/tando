package logs

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"tando/srv/internal/fsinfo"
	"tando/srv/internal/lock"
	"tando/srv/internal/out"
	"tando/srv/logs/lines"
	"tando/srv/logs/reqlog"
)

// The request index (reqlog/index.go): Lib/logscan/<app>/reqindex/ (root 700, like the rest of the
// scan state: paths and addresses are not for other users):
//
//	state      "tando-reqindex 2", then per segment: id off recs dictbytes keys flags ino size fp name
//	<id>.rec   32-byte records, one per parsed line of the log file, in its order
//	<id>.path  the path keys the records use (length-prefixed)
//	lock       taken by Roll
//
// A segment shadows one file of the request log: the current access.log (records cover its first
// off bytes, whole lines; the rest is read from the log), a rolled one, or its gzip'd form (Caddy
// gzips rolled files: the segment follows it by name and first line). A segment lives as long as
// its file: retention is Caddy's (roll_keep, roll_keep_for, request_log_max), and the index is
// about a tenth of the uncompressed log. Records are appended and state replaced atomically after
// them, so a reader never sees half a record and a killed Roll loses nothing it had saved; a
// reader that finds no usable segment for a file reads the file itself.
const (
	indexVersion   = "tando-reqindex 2"
	indexMaxDict   = 1 << 20   // path keys per segment, bytes: a client spraying unique paths makes the segment raw-read
	indexFlush     = 256 << 10 // records buffered before an append
	indexSaveBytes = 16 << 20
	indexLock      = 20 * time.Second
	// what one roll reads at most (it goes on at the next: a sparse multi-terabyte file costs a
	// bounded time a minute), and what a gzip'd file may decompress to in all (a gzip bomb is
	// read from the log by the verbs that ask for it, not indexed)
	rollBudget = 128 << 20
	gzipMax    = 512 << 20

	segComplete = 1 // the file is rolled and was read to its end
	segRaw      = 2 // paths over indexMaxKeys, or a status a record cannot hold: summaries read the file
)

type segment struct {
	ID, Flags       int
	Off, Recs, Dict int64
	Keys            int
	Ino             uint64
	Size            int64 // a gzip'd file's size when it was read to its end (it never changes after)
	FP, Name        string
	file            *logFile // set by Roll and the readers
	dict            *reqlog.Dict
	recs            []byte
	added           int64
}

type reqIndex struct {
	dir    string
	next   int
	budget int64 // bytes this roll may still read
	segs   []*segment
	sc     *ScanCache
	as     *appScan
}

func (a *app) indexDir() string { return filepath.Join(a.scanDir(), "reqindex") }

// loadIndex reads the state; a missing, torn or malformed one is empty (the index is then
// rebuilt). Every field is checked for its shape: a name the log directory could not hold, a
// count out of range, more segments than files are listed, all mean "rebuild", never "trust".
func loadIndex(dir string) (*reqIndex, bool) {
	x := &reqIndex{dir: dir}
	raw, err := os.ReadFile(filepath.Join(dir, "state"))
	if err != nil {
		return x, false
	}
	b, whole := unseal(raw)
	if !whole { // torn, or from before the seal: built again from the log
		return x, false
	}
	ls := strings.Split(strings.TrimSuffix(b, "\n"), "\n")
	if ls[0] != indexVersion || len(ls)-1 > maxLogFiles+1 {
		return x, false
	}
	ids := map[int]bool{}
	for _, l := range ls[1:] {
		s, ok := parseSegment(l)
		if !ok || ids[s.ID] {
			return &reqIndex{dir: dir}, false
		}
		ids[s.ID] = true
		x.segs = append(x.segs, s)
		x.next = max(x.next, s.ID+1)
	}
	return x, true
}

var reFP = regexp.MustCompile(`^(-|[0-9a-f]{1,16})$`)

// parseSegment: "id off recs dict keys flags ino size fp name", each in its range.
func parseSegment(l string) (*segment, bool) {
	f := strings.Split(l, " ")
	if len(f) != 10 || !reFP.MatchString(f[8]) || !reLogName.MatchString(f[9]) && f[9] != "access.log" {
		return nil, false
	}
	var n [8]int64
	for i, lim := range [8]int64{1 << 30, 1 << 50, 1 << 45, indexMaxDict + reqlog.MaxKeyLen + 2, 1 << 24, segComplete | segRaw, 1<<63 - 1, 1 << 50} {
		v, err := strconv.ParseInt(f[i], 10, 64)
		if err != nil || v < 0 || v > lim || strconv.FormatInt(v, 10) != f[i] {
			return nil, false
		}
		n[i] = v
	}
	return &segment{ID: int(n[0]), Off: n[1], Recs: n[2], Dict: n[3], Keys: int(n[4]), Flags: int(n[5]), Ino: uint64(n[6]),
		Size: n[7], FP: f[8], Name: f[9]}, true
}

func (x *reqIndex) save() error {
	b := sealed(x.serialize())
	if x.as != nil && x.as.idxSig.ok && b == x.as.idxBytes {
		return nil // unchanged (no read of the file to know it)
	}
	// no fsync: a state lost in a crash is an older one or none, and a segment whose files do not
	// match its state is read again (intact, extend's truncation), so the index stays right
	p := filepath.Join(x.dir, "state")
	if err := writeInPlace(p, []byte(b), 0o600); err != nil {
		return err
	}
	if x.as != nil {
		x.as.idxBytes, x.as.idxSig = b, x.sc.st.stat(cpath(p))
	}
	return nil
}

func (x *reqIndex) serialize() string {
	var b strings.Builder
	b.WriteString(indexVersion + "\n")
	for _, s := range x.segs {
		fmt.Fprintf(&b, "%d %d %d %d %d %d %d %d %s %s\n", s.ID, s.Off, s.Recs, s.Dict, s.Keys, s.Flags, s.Ino, s.Size, s.FP, s.Name)
	}
	return b.String()
}

func (x *reqIndex) path(s *segment, ext string) string {
	return filepath.Join(x.dir, strconv.Itoa(s.ID)+ext)
}

// RollStats: what one Roll read (for the watch scan, which reads the index after its own
// position anyway, and for measurements).
type RollStats struct {
	Lines, Bytes int64
	Built        bool // there was no index: this run built it from the whole log
}

// Roll brings the app's request index up to date with its log: O(bytes written since), no cap,
// one at a time (a lock), safe while readers read. Called by req-roll, by watch-scan every
// minute, and by req-summary first; a long-running caller may call it in-process.
func (l *Logs) Roll(ctx context.Context, name string) (RollStats, error) {
	a, err := l.app(name)
	if err != nil {
		return RollStats{}, err
	}
	return a.rollIndex(ctx)
}

func (a *app) rollIndex(ctx context.Context) (RollStats, error) {
	var st RollStats
	sc, as := a.cached()
	dir := a.indexDir()
	if !as.dirsOK {
		for _, p := range []string{a.l.scanDir(), a.scanDir(), dir} {
			if err := ensureDir(p, 0o700, -1, -1); err != nil {
				return st, err
			}
		}
		as.dirsOK = true
	}
	lk, err := lock.Acquire(filepath.Join(dir, "lock"), indexLock)
	if err != nil {
		as.dirsOK = false
		return st, err
	}
	defer lk.Release()
	// the index in memory (its dictionaries loaded) while its state file is the one this cache
	// wrote or read; else from the files
	x, ok := as.idx, true
	if x == nil || !as.idxSig.ok || sc.st.stat(cpath(filepath.Join(dir, "state"))) != as.idxSig {
		x, ok = loadIndex(dir)
		as.idxSig, as.idxBytes = fsig{}, ""
		st.Built = !ok
		if !ok {
			clearIndex(dir)
		}
	}
	x.sc, x.as = sc, as
	x.budget = rollBudget
	as.idx = x
	files := a.listLog()
	if len(files) == 0 && !ok {
		return st, x.save()
	}
	x.match(files)
	var work []*segment
	for _, s := range x.segs {
		if s.file != nil && !x.intact(s) { // damaged files: the segment is read again
			os.Remove(x.path(s, ".rec"))
			os.Remove(x.path(s, ".path"))
			*s = segment{ID: x.next, Name: s.Name, FP: "-", Ino: s.Ino, file: s.file}
			x.next++
		}
		if s.file != nil && s.Flags&segComplete == 0 {
			work = append(work, s)
		}
	}
	sort.SliceStable(work, func(i, j int) bool { return work[i].file.mtime < work[j].file.mtime })
	if err := x.save(); err != nil { // (the matching: renames, new and dropped segments)
		return st, err
	}
	for _, s := range work {
		if err := ctx.Err(); err != nil {
			return st, err
		}
		if err := x.extend(ctx, s, &st); err != nil {
			return st, err
		}
	}
	err = x.save()
	if err != nil {
		as.idx = nil
	}
	sc.trimDicts(x)
	if st.Lines > 0 && a.l.Trim != nil && a.l.Cache == nil { // (a cache's owner keeps its memory)
		a.l.Trim()
	}
	return st, err
}

func clearIndex(dir string) {
	ents, _ := os.ReadDir(dir)
	for _, e := range ents {
		if n := e.Name(); strings.HasSuffix(n, ".rec") || strings.HasSuffix(n, ".path") {
			os.Remove(filepath.Join(dir, n))
		}
	}
}

// match pairs files with segments: a plain file by inode (whatever its name now: the current
// file rolls under a new name), confirmed by its first line; a gzip'd roll by its own name, size
// and first line, or by the name of the plain file it was and its first line. A file without a
// segment gets a new one; a segment without a file goes. Maps, not files x segments.
func (x *reqIndex) match(files []*logFile) {
	used := map[*segment]bool{}
	byIno := map[uint64][]*segment{}
	byName := map[string]*segment{}
	for _, s := range x.segs {
		if !strings.HasSuffix(s.Name, ".gz") {
			byIno[s.Ino] = append(byIno[s.Ino], s)
		}
		byName[s.Name] = s
	}
	take := func(f *logFile, s *segment) {
		used[s] = true
		s.Name, s.file = f.name, f
		if !f.gz {
			s.Ino = f.ino
		}
		if s.Off > 0 && s.FP == "-" {
			s.FP = fingerprint(f)
		}
	}
	matched := map[*logFile]bool{}
	for _, f := range files {
		if f.gz {
			continue
		}
		for _, s := range byIno[f.ino] {
			if used[s] || f.size < s.Off || s.FP != "-" && fingerprint(f) != s.FP {
				continue
			}
			take(f, s)
			matched[f] = true
			break
		}
	}
	for _, f := range files {
		if !f.gz {
			continue
		}
		if s := byName[f.name]; s != nil && !used[s] && (s.Flags&segComplete == 0 || s.Size == f.size) && (s.FP == "-" || fingerprint(f) == s.FP) {
			take(f, s)
			matched[f] = true
			continue
		}
		if s := byName[strings.TrimSuffix(f.name, ".gz")]; s != nil && !used[s] && s.FP != "-" && fingerprint(f) == s.FP {
			take(f, s)
			// (Caddy removes the plain file once the gzip'd one is written: its size is final; a
			// segment not read to its end gets it when it is)
			s.Size = f.size
			matched[f] = true
		}
	}
	for _, f := range files {
		if !matched[f] {
			s := &segment{ID: x.next, FP: "-"}
			x.next++
			x.segs = append(x.segs, s)
			take(f, s)
		}
	}
	var keep []*segment
	for _, s := range x.segs {
		if used[s] {
			keep = append(keep, s)
			continue
		}
		os.Remove(x.path(s, ".rec"))
		os.Remove(x.path(s, ".path"))
	}
	x.segs = keep
}

// intact: the segment's files hold at least what its state says (a stat each).
func (x *reqIndex) intact(s *segment) bool {
	size := func(ext string) int64 {
		fi, err := os.Lstat(x.path(s, ext))
		if err != nil {
			return 0
		}
		return fi.Size()
	}
	return size(".rec") >= s.Recs*reqlog.RecordSize && size(".path") >= s.Dict
}

// extend reads segment s's file from s.Off: whole lines of the current file, all of a rolled one.
func (x *reqIndex) extend(ctx context.Context, s *segment, st *RollStats) error {
	f := s.file
	rolled := f.name != "access.log"
	if err := x.dropUnsaved(s); err != nil {
		return err
	}
	r, closer, ok := openFrom(f, s.Off)
	if !ok {
		return nil // gone meanwhile (the next run drops its segment), or a gzip file still being written
	}
	defer closer()
	if x.sc.parser == nil {
		x.sc.parser = reqlog.NewParser()
	}
	p := x.sc.parser
	var req reqlog.Request
	var key, tmp []byte
	if x.sc.lr == nil {
		x.sc.lr = lines.NewReaderSize(r, reqlog.MaxLine, 64<<10)
	} else {
		x.sc.lr.Reset(r)
	}
	lr := x.sc.lr
	since, start := s.Off, s.Off
	stopped := false
	for {
		if s.Off-start >= x.budget || f.gz && s.Off >= gzipMax {
			stopped = true
			break
		}
		ln, ok := lr.Next()
		if !ok {
			break
		}
		if !ln.EOL && !rolled {
			break // the line being written: next time
		}
		off := s.Off
		s.Off += int64(ln.Len)
		if ln.EOL {
			s.Off++
		}
		st.Lines++
		if !p.Parse(ln.Text, &req) {
			continue
		}
		if !reqlog.Indexable(&req, off) {
			s.Flags |= segRaw
		}
		rec := reqlog.Record{Ts: req.Ts, Dur: req.Duration, Off: uint32(min(off, 1<<32-1)), Status: uint16(min(max(req.Status, 0), 65535)),
			Bin: uint16(reqlog.BinOf(req.Duration)), Path: reqlog.NotCounted}
		if req.Counted() {
			id, ok := x.pathID(s, &req, &key, &tmp)
			if !ok {
				return x.restart(ctx, s, st) // (this file stays open until return: closed once, by the defer)
			}
			rec.Path = id
		}
		var b [reqlog.RecordSize]byte
		rec.Put(b[:])
		s.recs = append(s.recs, b[:]...)
		s.added++
		if len(s.recs) >= indexFlush {
			if err := x.flush(s); err != nil {
				return err
			}
		}
		if s.Off-since >= indexSaveBytes { // progress survives a killed run
			if err := x.flush(s); err != nil {
				return err
			}
			if err := x.save(); err != nil {
				return err
			}
			since = s.Off
			if err := ctx.Err(); err != nil {
				return err
			}
		}
	}
	switch {
	case stopped && f.gz && s.Off >= gzipMax:
		s.Flags |= segComplete | segRaw
	case rolled && !stopped && lr.Err() == nil:
		s.Flags |= segComplete
		if f.gz {
			s.Size = f.size
		}
	}
	x.budget -= s.Off - start
	st.Bytes += s.Off - start
	if s.FP == "-" && s.Off > 0 {
		s.FP = fingerprint(f)
	}
	return x.flush(s)
}

// dropUnsaved truncates the segment's files to what its state says: what a killed run appended
// after its last saved state goes. A dictionary in memory that is not what the file holds is
// dropped (read again when a new line first needs a key).
func (x *reqIndex) dropUnsaved(s *segment) error {
	if err := truncateTo(x.path(s, ".rec"), s.Recs*reqlog.RecordSize); err != nil {
		return err
	}
	if err := truncateTo(x.path(s, ".path"), s.Dict); err != nil {
		return err
	}
	if s.dict != nil && (s.dict.Len() != s.Keys || s.dict.Pending()) {
		s.dict = nil
	}
	return nil
}

// pathID is the dictionary id of a counted request's path key (key and tmp are reused buffers);
// a dictionary over its bound gives the id of "other paths" and marks the segment raw. false:
// the dictionary file is not what the state says (the segment is read again from the start).
func (x *reqIndex) pathID(s *segment, req *reqlog.Request, key, tmp *[]byte) (uint32, bool) {
	if s.dict == nil {
		keys, ok := loadKeys(x.path(s, ".path"), s.Dict)
		if !ok || keys.Len() != s.Keys {
			return 0, false
		}
		s.dict = reqlog.NewDict(keys)
	}
	*key = reqlog.PathKey((*key)[:0], req.Method, req.URI, tmp)
	id, ok := s.dict.ID(*key, indexMaxDict)
	if !ok {
		s.Flags |= segRaw
		id = reqlog.NotCounted - 1
	}
	return id, true
}

// restart drops a segment's damaged files and reads its file again from the start.
func (x *reqIndex) restart(ctx context.Context, s *segment, st *RollStats) error {
	os.Remove(x.path(s, ".rec"))
	os.Remove(x.path(s, ".path"))
	f := s.file
	*s = segment{ID: x.next, Name: s.Name, FP: "-", Ino: s.Ino, file: f}
	x.next++
	return x.extend(ctx, s, st)
}

// flush appends the buffered records and the new keys (one write each), then counts them in s.
func (x *reqIndex) flush(s *segment) error {
	if s.dict != nil && len(s.dict.Unsaved()) > 0 {
		b := s.dict.Unsaved()
		if err := appendFile(x.path(s, ".path"), b); err != nil {
			return err
		}
		s.Dict += int64(len(b))
		s.Keys = s.dict.Len()
		s.dict.Saved()
	}
	if len(s.recs) > 0 {
		if err := appendFile(x.path(s, ".rec"), s.recs); err != nil {
			return err
		}
		s.Recs += int64(len(s.recs) / reqlog.RecordSize)
		s.recs = nil // (not kept between rolls: a cache holds segments of many apps)
	}
	return nil
}

// ReqRoll (req-roll [app]): bring the request index of one app, or of every app with a request
// log, up to date; one row per app: roll <app> <lines read> <bytes read> <built 0|1>.
func (l *Logs) ReqRoll(ctx context.Context, name string, w *out.Writer) error {
	if err := l.needRoot(); err != nil {
		return err
	}
	names := []string{name}
	if name == "" {
		names = l.appDirs()
	}
	for _, n := range names {
		a, err := l.app(n)
		if err != nil {
			if name != "" {
				return err
			}
			l.warn("tando-logs: %v", err)
			continue
		}
		if name == "" && !fsinfo.RegularNoFollow(filepath.Join(a.logDir(), "access.log")) {
			continue
		}
		st, err := a.rollIndex(ctx)
		if err != nil {
			l.warn("tando-logs: request index of %s: %v", n, err)
			continue
		}
		built := "0"
		if st.Built {
			built = "1"
		}
		w.Row("roll", n, strconv.FormatInt(st.Lines, 10), strconv.FormatInt(st.Bytes, 10), built)
	}
	return nil
}
