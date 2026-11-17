package logs

// req-tail follow: the last n lines, then each new line as Caddy writes it, across its rolls.

import (
	"context"
	"io"
	"os"
	"time"

	"tando/srv/internal/out"
	"tando/srv/logs/reqlog"
)

// tailPoll: how often a followed file is checked for new lines and for a roll.
const tailPoll = 300 * time.Millisecond

// tailFollow is `tail -n n -F access.log`: the last n lines, then whatever is appended; after a
// roll (a new file under the name) the old one is read to its end and the new one from its
// start, after a truncation from the start again. Ends when the client goes away (a write
// fails) or ctx ends.
func (l *Logs) tailFollow(ctx context.Context, path string, n int, w *out.Writer, flush func() error) error {
	f, err := openRegular(path)
	if err != nil {
		return err
	}
	defer func() { f.Close() }()
	pos, err := tailStart(f, n)
	if err != nil {
		return err
	}
	p := reqlog.NewParser()
	var r reqlog.Request
	var pending []byte
	rolled := false
	buf := make([]byte, 64<<10)
	emit := func(line []byte) error {
		if len(line) > reqlog.MaxLine || !p.Parse(line, &r) {
			return nil
		}
		row, ok := reqlog.RowFilter{}.Make(&r)
		if !ok {
			return nil
		}
		w.Row(append([]string{"req"}, row[:]...)...)
		return flush()
	}
	for {
		k, rerr := f.ReadAt(buf, pos)
		if k > 0 {
			pos += int64(k)
			data := buf[:k]
			for {
				i := indexNL(data)
				if i < 0 {
					if len(pending) < reqlog.MaxLine+1 {
						pending = append(pending, data[:min(len(data), reqlog.MaxLine+1-len(pending))]...)
					}
					break
				}
				line := data[:i]
				if len(pending) > 0 {
					line = append(pending, line...)
					pending = pending[:0]
				}
				if err := emit(line); err != nil {
					return err
				}
				data = data[i+1:]
			}
			continue
		}
		if rerr != nil && rerr != io.EOF {
			return rerr
		}
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(tailPoll):
		}
		fi, err := os.Lstat(path)
		cur, _ := f.Stat()
		switch {
		case err == nil && cur != nil && !os.SameFile(fi, cur) && fi.Mode().IsRegular():
			if rolled {
				// rolled, and the old file was read to its end after the roll: the new one from
				// its start
				nf, err := openRegular(path)
				if err != nil {
					continue
				}
				f.Close()
				f, pos, pending, rolled = nf, 0, pending[:0], false
				continue
			}
			rolled = true // read what was written to the old file just before the roll first
		case cur != nil && cur.Size() < pos:
			pos, pending = 0, pending[:0] // truncated
		}
	}
}

func indexNL(b []byte) int {
	for i, c := range b {
		if c == '\n' {
			return i
		}
	}
	return -1
}

// tailStart: the offset where the last n lines of f begin (a last line without its newline
// counts as one, as tail does).
func tailStart(f *os.File, n int) (int64, error) {
	fi, err := f.Stat()
	if err != nil {
		return 0, err
	}
	size := fi.Size()
	if n == 0 {
		return size, nil
	}
	buf := make([]byte, 64<<10)
	pos := size
	seen := 0
	end := size
	// a final newline ends the last line; it does not start a new one
	for pos > 0 {
		k := int64(len(buf))
		if pos < k {
			k = pos
		}
		pos -= k
		if _, err := f.ReadAt(buf[:k], pos); err != nil && err != io.EOF {
			return 0, err
		}
		for i := k - 1; i >= 0; i-- {
			if buf[i] != '\n' || pos+i == end-1 {
				continue
			}
			seen++
			if seen == n {
				return pos + i + 1, nil
			}
		}
	}
	return 0, nil
}

// lastLinesStart: where the last n lines of a plain file begin, reading it from the end; ok is
// false when it has fewer than n lines (a last line without its newline counts, as for tail).
func lastLinesStart(rf *reqFile, n int) (int64, bool) {
	buf := make([]byte, 64<<10)
	pos, end := rf.size, rf.size
	seen := 0
	for pos > 0 {
		k := min(int64(len(buf)), pos)
		pos -= k
		if _, err := rf.f.ReadAt(buf[:k], pos); err != nil && err != io.EOF {
			return 0, false
		}
		for i := k - 1; i >= 0; i-- {
			if buf[i] != '\n' || pos+i == end-1 {
				continue
			}
			if seen++; seen == n {
				return pos + i + 1, true
			}
		}
	}
	// the first line has no newline before it: n lines exactly when n-1 newlines were seen
	return 0, rf.size > 0 && seen == n-1
}
