package logs

// The request index's read side: the segment that shadows an opened log file (a view of its
// records and keys), read by req-summary, req-errors and the watch scan.

import (
	"bufio"
	"io"
	"os"
	"path/filepath"
	"syscall"

	"tando/srv/logs/reqlog"
)

// segView: a usable segment for an opened log file, its records and keys, or nil (read the file).
// A plain file's records cover [0, Off); a gzip'd one's all of it.
type segView struct {
	s    *segment
	recs string // the .rec file, read through a buffer (a segment's records are not held whole)
	keys reqlog.SegView
}

// each calls fn for the view's records in order, false when the file is shorter than its state.
func (v *segView) each(fn func(*reqlog.Record) bool) bool { return eachRecord(v.recs, 0, v.s.Recs, fn) }

// eachRecord calls fn for records [from, to) of a .rec file.
func eachRecord(p string, from, to int64, fn func(*reqlog.Record) bool) bool {
	if from >= to {
		return true
	}
	f, err := os.Open(p)
	if err != nil {
		return false
	}
	defer f.Close()
	if _, err := f.Seek(from*reqlog.RecordSize, io.SeekStart); err != nil {
		return false
	}
	br := bufio.NewReaderSize(f, int(min(256<<10, max(4096, (to-from)*reqlog.RecordSize))))
	var rec reqlog.Record
	var b [reqlog.RecordSize]byte
	for n := from; n < to; n++ {
		if _, err := io.ReadFull(br, b[:]); err != nil {
			return false
		}
		rec.Get(b[:])
		if !fn(&rec) {
			return false
		}
	}
	return true
}

// views loads, for each of the opened files, the segment that shadows it (nil where none can).
func (a *app) views(files []*reqFile) []*segView {
	x, ok := loadIndex(a.indexDir())
	v := make([]*segView, len(files))
	if !ok {
		return v
	}
	for i, rf := range files {
		fi, err := rf.f.Stat()
		if err != nil {
			continue
		}
		var ino uint64
		if st, ok := fi.Sys().(*syscall.Stat_t); ok {
			ino = uint64(st.Ino)
		}
		for _, s := range x.segs {
			if s.Name != filepath.Base(rf.f.Name()) || s.Flags&segRaw != 0 {
				continue
			}
			if rf.gz && (s.Flags&segComplete == 0 || s.Size != rf.size) || !rf.gz && (s.Ino != ino || s.Off > rf.size) {
				break
			}
			keys, kok := loadKeys(x.path(s, ".path"), s.Dict)
			if !kok || keys.Len() != s.Keys {
				break
			}
			v[i] = &segView{s: s, recs: x.path(s, ".rec"), keys: reqlog.SegView{Keys: keys}}
			break
		}
	}
	return v
}

// loadKeys reads the first size bytes of a dictionary file.
func loadKeys(p string, size int64) (reqlog.Keys, bool) {
	if size == 0 {
		return reqlog.Keys{}, true
	}
	if size < 0 || size > indexMaxDict+reqlog.MaxKeyLen+2 { // (a damaged state: the segment is read again)
		return reqlog.Keys{}, false
	}
	f, err := os.Open(p)
	if err != nil {
		return reqlog.Keys{}, false
	}
	defer f.Close()
	return reqlog.LoadKeys(f, size)
}
