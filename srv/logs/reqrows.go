package logs

// The rows of the request log: req-tail and req-errors (the last n rows, from the index where
// it can say, else from the files, within a memory budget).

import (
	"context"
	"errors"
	"fmt"
	"io"
	"path/filepath"

	"tando/srv/internal/decimal"
	"tando/srv/internal/fsinfo"
	"tando/srv/internal/lock"
	"tando/srv/internal/out"
	"tando/srv/logs/lines"
	"tando/srv/logs/reqlog"
)

// rowBudget bounds the bytes of rows held for tail and errors; a log of very long paths then
// takes a second pass instead of memory.
const rowBudget = 16 << 20

// lastRows writes the rows of the last n lines (tail: every line counts, shown or not) or of the
// last n shown rows (errors), oldest first.
func lastRows(files []*reqFile, n int, f reqlog.RowFilter, perLine bool, w *out.Writer) {
	if n == 0 {
		return
	}
	p := reqlog.NewParser()
	var r reqlog.Request
	ring := make([]*reqlog.Row, n)
	next, total, bytes := 0, 0, 0
	over := false
	eachLine(files, func(ln lines.Line) bool {
		var row *reqlog.Row
		if !f.Skips(ln.Text) && p.Parse(ln.Text, &r) {
			if x, ok := f.Make(&r); ok {
				row = &x
			}
		}
		if row == nil && !perLine {
			return true
		}
		if old := ring[next]; old != nil {
			bytes -= rowSize(old)
		}
		ring[next] = row
		if row != nil {
			bytes += rowSize(row)
		}
		next = (next + 1) % n
		total++
		if bytes > rowBudget {
			over = true
			return false
		}
		return true
	})
	if !over {
		for i := 0; i < n; i++ {
			if row := ring[(next+i)%n]; row != nil {
				w.Row(append([]string{"req"}, row[:]...)...)
			}
		}
		return
	}
	// second pass: count, then print from the n-th last on (the files are the same open files
	// with the same sizes, so both passes see the same lines)
	count := 0
	eachLine(files, func(ln lines.Line) bool {
		if perLine {
			count++
		} else if !f.Skips(ln.Text) && p.Parse(ln.Text, &r) {
			if _, ok := f.Make(&r); ok {
				count++
			}
		}
		return true
	})
	i := 0
	eachLine(files, func(ln lines.Line) bool {
		ok := !f.Skips(ln.Text) && p.Parse(ln.Text, &r)
		var row reqlog.Row
		if ok {
			row, ok = f.Make(&r)
		}
		if !ok && !perLine {
			return true
		}
		i++
		if i > count-n && ok {
			w.Row(append([]string{"req"}, row[:]...)...)
		}
		return true
	})
}

func rowSize(r *reqlog.Row) int {
	n := 64
	for _, s := range r {
		n += len(s)
	}
	return n
}

// ReqTail (req-tail <app> <n> [follow]): the newest n requests across the current file and the
// newest rolled one (a roll may just have happened); follow streams new ones as Caddy writes
// them, from the last n lines of the current file.
func (l *Logs) ReqTail(ctx context.Context, name, count, mode string, w *out.Writer, flush func() error) error {
	if err := l.needRoot(); err != nil {
		return err
	}
	a, err := l.app(name)
	if err != nil {
		return err
	}
	if count == "" {
		count = "20"
	}
	n, ok := decimal.Parse(count, 5)
	if !ok {
		return errors.New("bad count")
	}
	cur := filepath.Join(a.logDir(), "access.log")
	if !fsinfo.RegularNoFollow(cur) { // (Caddy's directory: a link there is not the log)
		return fmt.Errorf("no request log for %s (access_log = off, or no request yet)", a.name)
	}
	if mode == "follow" {
		return l.tailFollow(ctx, cur, int(n), w, flush)
	}
	files := a.reqFiles(0)
	defer closeAll(files)
	if len(files) > 2 {
		closeAll(files[:len(files)-2])
		files = files[len(files)-2:]
	}
	// the newest file holds n lines or more (the usual case): only its end is read
	if len(files) > 0 && !files[len(files)-1].gz && n > 0 {
		last := files[len(files)-1]
		if start, ok := lastLinesStart(last, int(n)); ok {
			p := reqlog.NewParser()
			var r reqlog.Request
			eachLineOf(last, start, func(ln lines.Line) bool {
				if p.Parse(ln.Text, &r) {
					if row, ok := (reqlog.RowFilter{}).Make(&r); ok {
						w.Row(append([]string{"req"}, row[:]...)...)
					}
				}
				return true
			})
			return nil
		}
	}
	lastRows(files, int(n), reqlog.RowFilter{}, true, w)
	return nil
}

// ReqErrors (req-errors <app> <seconds> <n> [4xx]): the newest n answers of 5xx (or 4xx and 5xx)
// within the window, and requests the client aborted.
func (l *Logs) ReqErrors(ctx context.Context, name, window, count, four string, w *out.Writer) error {
	if err := l.needRoot(); err != nil {
		return err
	}
	a, err := l.app(name)
	if err != nil {
		return err
	}
	if window == "" {
		window = "3600"
	}
	if count == "" {
		count = "20"
	}
	ws, ok1 := decimal.Parse(window, 6)
	n, ok2 := decimal.Parse(count, 4)
	if !ok1 || !ok2 {
		return errors.New("bad window or count")
	}
	now := l.Env.Now().Unix()
	if _, err := a.rollIndex(ctx); err != nil && !errors.Is(err, lock.ErrBusy) {
		l.warn("tando-logs: request index: %v", err)
	}
	files := a.reqFiles(now - ws)
	defer closeAll(files)
	f := reqlog.RowFilter{From: float64(now - ws), MinStatus: 500}
	if four == "4xx" {
		f.MinStatus = 400
	}
	if !indexedRows(files, a.views(files), int(n), f, w) {
		lastRows(files, int(n), f, false, w)
	}
	return nil
}

// indexedRows is lastRows for errors from the index: the records pick the newest n matching
// lines (a record holds the line's time, status and whether it is a request: the filter's whole
// decision) and only those lines are read back from the log, at their offsets; the lines written
// after a plain file's records are read as lines. false (nothing written) when a file of the
// window has no usable segment or a line cannot be read back.
func indexedRows(files []*reqFile, views []*segView, n int, f reqlog.RowFilter, w *out.Writer) bool {
	for _, v := range views {
		if v == nil {
			return false
		}
	}
	if n == 0 {
		return true
	}
	type ref struct {
		file int
		off  int64
		row  *reqlog.Row // a tail line, already made
	}
	ring := make([]ref, n)
	next, total := 0, 0
	push := func(r ref) {
		ring[next] = r
		next = (next + 1) % n
		total++
	}
	p := reqlog.NewParser()
	var req reqlog.Request
	for i, rf := range files {
		v := views[i]
		ok := v.each(func(r *reqlog.Record) bool {
			st := float64(r.Status)
			if r.Ts < f.From || (st < f.MinStatus && st != 0) || r.Path == reqlog.NotCounted {
				return true
			}
			push(ref{file: i, off: int64(r.Off)})
			return true
		})
		if !ok {
			return false
		}
		if !rf.gz && v.s.Off < rf.size {
			eachLineOf(rf, v.s.Off, func(ln lines.Line) bool {
				if !f.Skips(ln.Text) && p.Parse(ln.Text, &req) {
					if row, ok := f.Make(&req); ok {
						push(ref{row: &row})
					}
				}
				return true
			})
		}
	}
	k := min(total, n)
	refs := make([]ref, k)
	for j := range k {
		refs[j] = ring[(next-k+j+n)%n]
	}
	// read the lines back: by offset in a plain file, in one pass through a gzip'd one
	rows := make([]*reqlog.Row, k)
	want := map[int]map[int64][]int{}
	for j, r := range refs {
		if r.row != nil {
			rows[j] = r.row
			continue
		}
		if want[r.file] == nil {
			want[r.file] = map[int64][]int{}
		}
		want[r.file][r.off] = append(want[r.file][r.off], j)
	}
	for fi, offs := range want {
		got := readLinesAt(files[fi], offs)
		for off, js := range offs {
			line, ok := got[off]
			if !ok || !p.Parse(line, &req) {
				return false
			}
			row, ok := f.Make(&req)
			if !ok {
				return false
			}
			for _, j := range js {
				rows[j] = &row
			}
		}
	}
	for _, r := range rows {
		w.Row(append([]string{"req"}, r[:]...)...)
	}
	return true
}

// readLinesAt: the lines of rf that start at the offsets wanted (uncompressed offsets).
func readLinesAt(rf *reqFile, want map[int64][]int) map[int64][]byte {
	got := map[int64][]byte{}
	if !rf.gz {
		for off := range want {
			lr := lines.NewReaderSize(io.NewSectionReader(rf.f, off, rf.size-off), reqlog.MaxLine, 4096)
			if ln, ok := lr.Next(); ok {
				got[off] = append([]byte(nil), ln.Text...)
			}
		}
		return got
	}
	var off int64
	eachLineOf(rf, 0, func(ln lines.Line) bool {
		if _, ok := want[off]; ok {
			got[off] = append([]byte(nil), ln.Text...)
		}
		off += int64(ln.Len)
		if ln.EOL {
			off++
		}
		return len(got) < len(want)
	})
	return got
}
