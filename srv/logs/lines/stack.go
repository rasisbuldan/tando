package lines

import (
	"bytes"
	"io"
	"os"
)

// Stack collects lines and writes them back last first (the shell's tac): journalctl -r gives
// the newest lines first, the output wants them oldest first. Up to Limit bytes stay in memory;
// beyond that everything goes to an unlinked temporary file, so `tando logs -n 9999999` costs
// disk, not memory.
type Stack struct {
	Limit int // bytes kept in memory before spilling (0: 8 MiB)
	buf   []byte
	f     *os.File
	size  int64
	err   error
}

// Push adds a line (without its newline; it must not contain one).
func (s *Stack) Push(line []byte) {
	if s.err != nil {
		return
	}
	s.buf = append(s.buf, line...)
	s.buf = append(s.buf, '\n')
	limit := s.Limit
	if limit == 0 {
		limit = 8 << 20
	}
	if len(s.buf) >= limit {
		s.spill()
	}
}

func (s *Stack) spill() {
	if s.f == nil {
		f, err := os.CreateTemp("", "tando-logs-*")
		if err != nil {
			s.err = err
			return
		}
		os.Remove(f.Name()) // gone when closed, whatever happens
		s.f = f
	}
	n, err := s.f.Write(s.buf)
	s.size += int64(n)
	if err != nil {
		s.err = err
	}
	s.buf = s.buf[:0]
}

// WriteReversed writes the lines, last pushed first, each with its newline, and releases the
// temporary file.
func (s *Stack) WriteReversed(w io.Writer) error {
	if s.err != nil {
		return s.err
	}
	if s.f == nil {
		return writeReversed(w, s.buf, nil)
	}
	defer s.f.Close()
	if len(s.buf) > 0 {
		s.spill()
		if s.err != nil {
			return s.err
		}
	}
	const block = 256 << 10
	var pending []byte // the start of a line whose end was in a later block
	chunk := make([]byte, block)
	for pos := s.size; pos > 0; {
		n := int64(block)
		if pos < n {
			n = pos
		}
		pos -= n
		if _, err := s.f.ReadAt(chunk[:n], pos); err != nil {
			return err
		}
		data := append(append([]byte(nil), chunk[:n]...), pending...)
		head, err := splitReversed(w, data, pos == 0)
		if err != nil {
			return err
		}
		pending = head
	}
	return nil
}

// writeReversed writes the newline-terminated lines of data last first, then tail (a complete
// line or nothing).
func writeReversed(w io.Writer, data, tail []byte) error {
	if _, err := splitReversed(w, data, true); err != nil {
		return err
	}
	_, err := w.Write(tail)
	return err
}

// splitReversed writes the complete lines of data (each ends with "\n") last first. The bytes
// before the first "\n" may be the end of a line that started earlier: they are returned, or,
// when first is set (data starts the input), written last.
func splitReversed(w io.Writer, data []byte, first bool) ([]byte, error) {
	end := len(data)
	for end > 0 {
		i := bytes.LastIndexByte(data[:end-1], '\n')
		if i < 0 {
			break
		}
		if _, err := w.Write(data[i+1 : end]); err != nil {
			return nil, err
		}
		end = i + 1
	}
	if first {
		_, err := w.Write(data[:end])
		return nil, err
	}
	return data[:end], nil
}
