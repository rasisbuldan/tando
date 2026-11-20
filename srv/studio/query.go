package studio

import (
	"bufio"
	"context"
	"net/http"
	"strconv"
	"strings"
	"time"

	"tando/srv/studio/pgwire"
	"tando/srv/studio/sqlsplit"
)

// readOnlyMsg: what a refused statement says
const readOnlyMsg = "the studio is read-only: this statement is not run (tando db psql for writes and other commands)"

type queryReq struct {
	ID      string
	SQL     string
	MaxRows int `json:"max_rows"`
}

func validID(id string) bool {
	if id == "" || len(id) > 64 {
		return false
	}
	for _, c := range id {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}

// query: POST /api/query, the editor. The statements run one by one in the studio's read-only
// transaction (ro); the response streams:
//
//	{"id":..,"results":[...],"notices":[...],"error":{stmt,sqlstate,message,detail,hint,position},
//	 "types":{"oid":"name"},"ms":N,"tx":"read_only"}
//
// position is the error's 1-based character position in the text that was sent.
func (s *Studio) query(w http.ResponseWriter, r *http.Request) {
	var q queryReq
	if !decode(w, r, &q) {
		return
	}
	if !validID(q.ID) {
		apiErr(w, 400, "bad_request", "bad query id")
		return
	}
	if len(q.SQL) > MaxSQL {
		apiErr(w, 413, "too_large", "the SQL is longer than 256 KB")
		return
	}
	if q.MaxRows == 0 {
		q.MaxRows = DefaultRows
	}
	if q.MaxRows < 1 || q.MaxRows > MaxRows {
		apiErr(w, 400, "bad_request", "max_rows is 1 to 10000")
		return
	}
	stmts := sqlsplit.Split(q.SQL)
	if len(stmts) > MaxStmts {
		apiErr(w, 400, "bad_request", "more than 100 statements in one run")
		return
	}
	t0 := time.Now()
	// the accident guard, before anything runs: one refused statement and nothing of the batch runs
	for i, st := range stmts {
		if !sqlsplit.ReadOnly(st.Text) {
			w.Header().Set("Content-Type", "application/json; charset=utf-8")
			bw := bufio.NewWriter(w)
			j := &jw{w: bw}
			j.obj().k("id").s(q.ID).k("results").arr().aend().k("error").obj().k("stmt").i(int64(i)).
				k("sqlstate").s("25006").k("message").s(readOnlyMsg).k("position").i(int64(st.CP + 1)).end().
				k("ms").i(0).k("tx").s("read_only").end()
			bw.Flush()
			return
		}
	}
	ctx, cf := context.WithTimeout(r.Context(), 2*s.cfg.StmtLimit)
	defer cf()
	var bw *bufio.Writer
	err := s.ro(ctx, q.ID, s.cfg.StmtLimit, func(x *txn) error {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		bw = bufio.NewWriterSize(w, 32<<10)
		j := &jw{w: bw}
		j.obj().k("id").s(q.ID).k("results").arr()
		budget := RespBytes
		var notices []pgwire.Notice
		var fail *pgwire.Error
		failStmt := 0
		var broken error
		unknown := map[uint32]bool{}
		for i, st := range stmts {
			if x.db.TxStatus() != 'T' {
				fail, failStmt = &pgwire.Error{Code: "25000", Message: errTxEnded.Error()}, i
				break
			}
			sink := &resultSink{s: s, j: j, stmt: i, offset: st.CP, max: q.MaxRows, budget: &budget, onStop: x.cancel, unknown: unknown}
			res, err := x.exec(st.Text, nil, int32(q.MaxRows+1), CellBytes, RowBytes, sink)
			s.stmts.Add(1)
			notices = append(notices, res.Notices...)
			if err != nil {
				if sink.started {
					sink.finish("")
				}
				broken = err
				break
			}
			if res.Err != nil && !(res.Stopped && res.Err.Code == "57014") {
				if sink.started {
					sink.finish("")
				}
				fail, failStmt = res.Err, i
				if res.Err.Position > 0 {
					res.Err.Position += st.CP
				}
				break
			}
			sink.finish(res.Tag)
			if res.Stopped {
				break // the response is full
			}
			if x.db.TxStatus() == 'I' { // the statement ended the transaction: stop here
				fail, failStmt = &pgwire.Error{Code: "25000", Message: errTxEnded.Error()}, i
				break
			}
		}
		j.aend().k("notices").arr()
		for i, n := range notices {
			if i == 100 {
				break
			}
			j.obj().k("severity").s(n.Severity).k("message").s(n.Message).end()
		}
		j.aend()
		switch {
		case broken != nil:
			j.k("error").obj().k("stmt").i(int64(failStmt)).k("sqlstate").s("08006").k("message").s(broken.Error()).end()
		case fail != nil:
			j.k("error").obj().k("stmt").i(int64(failStmt)).k("sqlstate").s(fail.Code).k("message").s(fail.Message).
				k("detail").s(fail.Detail).k("hint").s(fail.Hint).k("position").i(int64(fail.Position)).end()
		}
		if broken == nil && len(unknown) > 0 && x.db.TxStatus() == 'T' {
			s.learnTypes(x, unknown)
		}
		j.k("types").obj()
		for oid := range unknown {
			if t := s.typeName(oid); t != "" {
				j.k(strconv.FormatUint(uint64(oid), 10)).s(t)
			}
		}
		j.end().k("ms").i(time.Since(t0).Milliseconds()).k("tx").s("read_only").end()
		return nil
	})
	if bw == nil {
		s.dbFail(w, err)
		return
	}
	bw.Flush()
}

// learnTypes: the names of types the built-in list does not have (format_type), kept for the session
func (s *Studio) learnTypes(x *txn, oids map[uint32]bool) {
	var b strings.Builder
	b.WriteByte('{')
	n := 0
	for o := range oids {
		if n == 200 {
			break
		}
		if n > 0 {
			b.WriteByte(',')
		}
		b.WriteString(strconv.FormatUint(uint64(o), 10))
		n++
	}
	b.WriteByte('}')
	rows, err := x.query(2, "SELECT oid::int8, format_type(oid, NULL) FROM pg_type WHERE oid = ANY($1::oid[])", b.String())
	if err != nil {
		return
	}
	for _, r := range rows {
		s.types.Store(uint32(i64(r[0])), str(r[1]))
	}
}
