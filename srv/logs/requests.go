package logs

import (
	"bufio"
	"compress/gzip"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"syscall"

	"tando/srv/internal/decimal"
	"tando/srv/internal/lock"
	"tando/srv/internal/out"
	"tando/srv/logs/lines"
	"tando/srv/logs/reqlog"
)

// reqFile is one file of the request log, opened, with the size it had then: a later read sees
// the same bytes even if Caddy rolls the file in between (its name changes, the open file does
// not).
type reqFile struct {
	f    *os.File
	size int64
	gz   bool
}

// reqFiles opens the access log files that may hold lines newer than since, oldest first:
// rolled files (gzip'd by Caddy once rolled; a fresh roll may still be plain) and the current
// one. A file's mtime is its newest line. Symlinks are not followed: the directory is Caddy's.
func (a *app) reqFiles(since int64) []*reqFile {
	dir := a.logDir()
	names, _ := logNames(dir)
	type cand struct {
		m    int64
		name string
	}
	var c []cand
	for _, n := range names {
		fi, err := os.Lstat(filepath.Join(dir, n))
		if err != nil || !fi.Mode().IsRegular() {
			continue
		}
		if m := fi.ModTime().Unix(); m >= since {
			c = append(c, cand{m, n})
		}
	}
	sort.Slice(c, func(i, j int) bool { return c[i].m < c[j].m || c[i].m == c[j].m && c[i].name < c[j].name })
	var files []*reqFile
	for _, x := range c {
		f, err := os.OpenFile(filepath.Join(dir, x.name), os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
		if err != nil {
			continue
		}
		fi, err := f.Stat()
		if err != nil || !fi.Mode().IsRegular() {
			f.Close()
			continue
		}
		var magic [2]byte
		n, _ := f.ReadAt(magic[:], 0)
		files = append(files, &reqFile{f: f, size: fi.Size(), gz: n == 2 && magic[0] == 0x1f && magic[1] == 0x8b})
	}
	return files
}

func closeAll(files []*reqFile) {
	for _, f := range files {
		f.f.Close()
	}
}

// eachLine reads the files in order, decompressing gzip'd ones (zcat -f), and calls fn for every
// line; fn returns false to stop. A damaged gzip file ends where it can no longer be read.
func eachLine(files []*reqFile, fn func(lines.Line) bool) {
	for _, rf := range files {
		if !eachLineOf(rf, 0, fn) {
			return
		}
	}
}

// eachLineOf reads one file from byte from on (uncompressed; a gzip'd file only from 0); false
// when fn stopped.
func eachLineOf(rf *reqFile, from int64, fn func(lines.Line) bool) bool {
	var r io.Reader = io.NewSectionReader(rf.f, from, rf.size-from)
	if rf.gz {
		zr, err := gzip.NewReader(bufio.NewReaderSize(r, 64<<10))
		if err != nil {
			return true
		}
		r = zr
	}
	lr := lines.NewReaderSize(r, reqlog.MaxLine, 256<<10)
	for {
		ln, ok := lr.Next()
		if !ok {
			return true
		}
		if !fn(ln) {
			return false
		}
	}
}

// ReqSummary (req-summary <app> <seconds>): one pass over the window (docs/LOGGING.md, "The
// summary verb").
func (l *Logs) ReqSummary(ctx context.Context, name, window string, w *out.Writer) error {
	if err := l.needRoot(); err != nil {
		return err
	}
	a, err := l.app(name)
	if err != nil {
		return err
	}
	if window == "" {
		window = "900"
	}
	ws, ok := decimal.Parse(window, 6)
	if !ok || ws < 60 || ws > 604800 {
		return errors.New("bad window")
	}
	nb := min(ws/60, 60)
	now := l.Env.Now().Unix()
	// the index first (what Caddy wrote since the last minute's run), then the files
	if _, err := a.rollIndex(ctx); err != nil && !errors.Is(err, lock.ErrBusy) {
		l.warn("tando-logs: request index: %v", err)
	}
	files := a.reqFiles(now - ws)
	defer closeAll(files)
	w.KV("files", strconv.Itoa(len(files)))
	s, ok := a.summarize(files, a.views(files), ws, now, nb)
	if !ok { // an index file did not match its state: the log alone, which is always right
		s, _ = a.summarize(files, make([]*segView, len(files)), ws, now, nb)
	}
	s.Write(w)
	return nil
}

// summarize folds each file's segment where one shadows it (its records, then the lines written
// after them) and reads the other files; ok is false when a segment turned out unusable midway.
func (a *app) summarize(files []*reqFile, views []*segView, ws, now, nb int64) (*reqlog.Summary, bool) {
	s := reqlog.NewSummary(ws, now, nb)
	p := reqlog.NewParser()
	var r reqlog.Request
	add := func(ln lines.Line) bool {
		if p.Parse(ln.Text, &r) {
			s.Add(&r)
		}
		return true
	}
	for i, rf := range files {
		v := views[i]
		if v == nil {
			eachLineOf(rf, 0, add)
			continue
		}
		if !v.each(func(rec *reqlog.Record) bool { return s.AddRecord(rec, &v.keys) }) {
			return s, false
		}
		if !rf.gz && v.s.Off < rf.size {
			eachLineOf(rf, v.s.Off, add)
		}
	}
	return s, true
}
