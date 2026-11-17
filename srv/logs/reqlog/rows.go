package reqlog

import "strconv"

// RowFilter selects the requests of req-tail and req-errors: from a time on, with a status of
// at least MinStatus. An aborted request (status 0, the client closed first) is always shown:
// the app ran it, and it is one of the errors.
type RowFilter struct {
	From      float64
	MinStatus float64
}

// Row is one "req" row: time, status (or "aborted"), latency ms, method, path, size, address.
type Row [7]string

// Make returns the row for r, ok false when the filter leaves it out.
func (f RowFilter) Make(r *Request) (Row, bool) {
	st := r.Status
	if r.Ts < f.From || (st < f.MinStatus && st != 0) || !r.Counted() {
		return Row{}, false
	}
	status := "aborted"
	if st != 0 {
		status = string(AppendNum(nil, st))
	}
	return Row{
		strconv.FormatFloat(r.Ts, 'f', 3, 64),
		status,
		strconv.FormatFloat(r.Duration*1000, 'f', 2, 64),
		string(AppendClean(nil, r.Method)),
		string(AppendClean(nil, r.URI)),
		string(AppendNum(nil, r.Size)),
		string(AppendClean(nil, r.Addr())),
	}, true
}

// Skips reports whether a line is left out by its Quick fields alone (then it needs no decoding).
func (f RowFilter) Skips(line []byte) bool {
	if t, ok := QuickTS(line); ok && t < f.From {
		return true
	}
	if f.MinStatus == 0 {
		return false
	}
	st, ok := QuickStatus(line)
	return ok && st < f.MinStatus && st != 0
}
