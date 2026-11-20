package studio

import (
	"bufio"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"tando/srv/studio/pgwire"
)

// Table browsing. The SQL the studio builds names only what the catalog returned: a request's
// schema, table and column are first looked up with bind parameters (unknown: 404) and only the
// names found are put into SQL, quoted by quoteIdent. Values (LIMIT, OFFSET) are parameters.

const tablesSQL = `SELECT n.nspname, c.relname, c.relkind::text, c.reltuples::int8,
  CASE WHEN c.relkind IN ('r','m','p') THEN pg_total_relation_size(c.oid) ELSE 0 END,
  coalesce(obj_description(c.oid, 'pg_class'), ''), has_table_privilege(c.oid, 'SELECT')
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r','p','v','m','f') AND n.nspname !~ '^pg_(toast|temp_|toast_temp_)'
  AND ($1::bool OR n.nspname NOT IN ('pg_catalog', 'information_schema'))
ORDER BY n.nspname <> 'public', n.nspname, c.relname LIMIT 2001`

const relSQL = `SELECT c.oid::int8, c.relkind::text, c.reltuples::int8,
  CASE WHEN c.relkind IN ('r','m','p') THEN pg_total_relation_size(c.oid) ELSE 0 END,
  coalesce(obj_description(c.oid, 'pg_class'), '')
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = $1 AND c.relname = $2 AND c.relkind IN ('r','p','v','m','f')`

// colsSQL: pk is the column's place in the primary key, 1-based (indkey, an int2vector, counts from 0)
const colsSQL = `SELECT a.attname, format_type(a.atttypid, a.atttypmod), a.atttypid::int8, t.typlen::int,
  a.attnotnull, coalesce(pg_get_expr(d.adbin, d.adrelid), ''), a.attidentity::text, a.attgenerated::text,
  coalesce(array_position(i.indkey::int2[], a.attnum) - array_lower(i.indkey::int2[], 1) + 1, 0)
FROM pg_attribute a JOIN pg_type t ON t.oid = a.atttypid
  LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
  LEFT JOIN pg_index i ON i.indrelid = a.attrelid AND i.indisprimary
WHERE a.attrelid = $1 AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum`

const idxSQL = `SELECT ic.relname, pg_get_indexdef(i.indexrelid), i.indisprimary, i.indisunique
FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid WHERE i.indrelid = $1
ORDER BY i.indisprimary DESC, ic.relname`

// browseLimit: table browsing is the studio's own SQL, quick or not worth waiting for; a shorter
// limit than the editor's keeps its locks and snapshot short
func (s *Studio) browseLimit() time.Duration { return min(BrowseLimit, s.cfg.StmtLimit) }

// quoteIdent: PostgreSQL's quoted identifier ("" for a "). Names come from the catalog, which
// cannot hold NUL.
func quoteIdent(s string) string { return `"` + strings.ReplaceAll(s, `"`, `""`) + `"` }

type column struct {
	Name, Type        string
	OID               uint32
	TypLen            int
	NotNull           bool
	Default, Identity string
	Generated         string
	PK                int
}

type relation struct {
	Schema, Name, Kind, Comment string
	OID                         string
	Est, Bytes                  int64
	Cols                        []column
}

var errNotFound = errors.New("no such table")

// query: a small catalog result in memory; every row must have n columns
func (x *txn) query(n int, sql string, params ...string) ([][]*string, error) {
	ps := make([][]byte, len(params))
	for i, p := range params {
		ps[i] = []byte(p)
	}
	c := &collect{}
	r, err := x.exec(sql, ps, 0, CellBytes, RowBytes, c)
	if err != nil {
		return nil, err
	}
	if r.Err != nil {
		return nil, r.Err
	}
	for _, row := range c.rows {
		if len(row) != n {
			return nil, errors.New("unexpected catalog answer")
		}
	}
	return c.rows, nil
}

func i64(p *string) int64 { v, _ := strconv.ParseInt(str(p), 10, 64); return v }

// lookup: the relation and its columns, from the catalog
func (x *txn) lookup(schema, name string) (*relation, error) {
	if strings.IndexByte(schema+name, 0) >= 0 || schema == "" || name == "" || len(schema)+len(name) > 200 {
		return nil, errNotFound
	}
	rows, err := x.query(5, relSQL, schema, name)
	if err != nil {
		return nil, err
	}
	if len(rows) != 1 {
		return nil, errNotFound
	}
	r := rows[0]
	rel := &relation{Schema: schema, Name: name, OID: str(r[0]), Kind: str(r[1]), Est: i64(r[2]), Bytes: i64(r[3]), Comment: str(r[4])}
	cols, err := x.query(9, colsSQL, rel.OID)
	if err != nil {
		return nil, err
	}
	for _, c := range cols {
		rel.Cols = append(rel.Cols, column{Name: str(c[0]), Type: str(c[1]), OID: uint32(i64(c[2])), TypLen: int(i64(c[3])),
			NotNull: str(c[4]) == "t", Default: str(c[5]), Identity: str(c[6]), Generated: str(c[7]), PK: int(i64(c[8]))})
	}
	return rel, nil
}

func (s *Studio) tables(w http.ResponseWriter, r *http.Request) {
	var rows [][]*string
	sys := "false"
	if r.URL.Query().Get("system") == "1" {
		sys = "true"
	}
	err := s.ro(r.Context(), "", s.browseLimit(), func(x *txn) error {
		var err error
		rows, err = x.query(7, tablesSQL, sys)
		return err
	})
	if err != nil {
		s.sqlFail(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	bw := bufio.NewWriter(w)
	j := &jw{w: bw}
	j.obj().k("more").bool(len(rows) > 2000).k("tables").arr()
	for i, t := range rows {
		if i == 2000 {
			break
		}
		j.obj().k("schema").s(str(t[0])).k("name").s(str(t[1])).k("kind").s(str(t[2])).k("est").i(i64(t[3])).
			k("bytes").i(i64(t[4])).k("comment").s(str(t[5])).k("select").bool(str(t[6]) == "t").end()
	}
	j.aend().end()
	bw.Flush()
}

// sqlFail: an error from a catalog request
func (s *Studio) sqlFail(w http.ResponseWriter, err error) {
	var e *pgwire.Error
	switch {
	case errors.Is(err, errNotFound):
		apiErr(w, 404, "not_found", "no such table or view")
	case errors.As(err, &e):
		apiErr(w, 400, "sql", err.Error())
	default:
		s.dbFail(w, err)
	}
}

func (s *Studio) table(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	var rel *relation
	var idx [][]*string
	err := s.ro(r.Context(), "", s.browseLimit(), func(x *txn) error {
		var err error
		if rel, err = x.lookup(q.Get("schema"), q.Get("name")); err != nil {
			return err
		}
		idx, err = x.query(4, idxSQL, rel.OID)
		return err
	})
	if err != nil {
		s.sqlFail(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	bw := bufio.NewWriter(w)
	j := &jw{w: bw}
	j.obj().k("schema").s(rel.Schema).k("name").s(rel.Name).k("kind").s(rel.Kind).k("est").i(rel.Est).
		k("bytes").i(rel.Bytes).k("comment").s(rel.Comment).k("columns").arr()
	for _, c := range rel.Cols {
		j.obj().k("name").s(c.Name).k("type").s(c.Type).k("oid").i(int64(c.OID)).k("nullable").bool(!c.NotNull).
			k("default").s(c.Default).k("pk").i(int64(c.PK)).k("identity").s(c.Identity).k("generated").s(c.Generated).end()
	}
	j.aend().k("indexes").arr()
	for _, i := range idx {
		j.obj().k("name").s(str(i[0])).k("def").s(str(i[1])).k("primary").bool(str(i[2]) == "t").
			k("unique").bool(str(i[3]) == "t").end()
	}
	j.aend().end()
	bw.Flush()
}

type rowsReq struct {
	Schema, Name  string
	Offset, Limit int
	Sort          string // a column, or ""
	Desc          bool
}

// buildRows: the page of a table, from the catalog's relation only. Wide (varlena) columns come
// cut by the server (a 100 MB jsonb does not cross the socket); a bytea also brings its length
// as a hidden column after the shown ones. Order: the sort column, then the primary key (ctid
// for a table without one), so pages are stable.
func buildRows(rel *relation, q rowsReq) (string, [][]byte, map[int]int, error) {
	if q.Offset < 0 || q.Offset > 1e9 || q.Limit < 1 || q.Limit > 500 {
		return "", nil, nil, errors.New("offset or limit out of range")
	}
	var sel, extra []string
	bytea := map[int]int{}
	sortOK := q.Sort == ""
	for i, c := range rel.Cols {
		id := quoteIdent(c.Name)
		switch {
		case c.OID == 17:
			sel = append(sel, "substring("+id+" from 1 for "+strconv.Itoa(BrowseBytea+1)+")")
			bytea[i] = len(rel.Cols) + len(extra)
			extra = append(extra, "octet_length("+id+")")
		case c.TypLen == -1 || c.TypLen == -2:
			sel = append(sel, "left(("+id+")::text, "+strconv.Itoa(BrowseChars+1)+")")
		default:
			sel = append(sel, id)
		}
		if c.Name == q.Sort {
			sortOK = true
		}
	}
	if !sortOK {
		return "", nil, nil, errNotFound
	}
	if len(sel) == 0 {
		sel = []string{"NULL AS \"(no columns)\""}
	}
	var order []string
	if q.Sort != "" {
		d := ""
		if q.Desc {
			d = " DESC"
		}
		order = append(order, quoteIdent(q.Sort)+d+" NULLS LAST")
	}
	pk := map[int]string{}
	for _, c := range rel.Cols {
		if c.PK > 0 {
			pk[c.PK] = quoteIdent(c.Name)
		}
	}
	for i := 1; i <= len(pk); i++ {
		if p, ok := pk[i]; ok && p != quoteIdent(q.Sort) {
			order = append(order, p)
		}
	}
	if len(pk) == 0 && (rel.Kind == "r" || rel.Kind == "m") {
		order = append(order, "ctid")
	}
	sql := "SELECT " + strings.Join(append(sel, extra...), ", ") + " FROM " + quoteIdent(rel.Schema) + "." + quoteIdent(rel.Name)
	if len(order) > 0 {
		sql += " ORDER BY " + strings.Join(order, ", ")
	}
	sql += " LIMIT $1 OFFSET $2"
	return sql, [][]byte{[]byte(strconv.Itoa(q.Limit + 1)), []byte(strconv.Itoa(q.Offset))}, bytea, nil
}

func (s *Studio) rows(w http.ResponseWriter, r *http.Request) {
	var q rowsReq
	if !decode(w, r, &q) {
		return
	}
	started := false
	var bw *bufio.Writer
	err := s.ro(r.Context(), "", s.browseLimit(), func(x *txn) error {
		rel, err := x.lookup(q.Schema, q.Name)
		if err != nil {
			return err
		}
		sql, params, bytea, err := buildRows(rel, q)
		if err != nil {
			return err
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		bw = bufio.NewWriterSize(w, 32<<10)
		started = true
		j := &jw{w: bw}
		budget := RespBytes
		j.obj().k("offset").i(int64(q.Offset)).k("limit").i(int64(q.Limit)).k("result")
		sink := &resultSink{s: s, j: j, max: q.Limit, budget: &budget, browse: true, bytea: bytea, ncols: len(rel.Cols)}
		if len(rel.Cols) == 0 {
			sink.ncols = 1
		}
		res, err := x.exec(sql, params, int32(q.Limit+1), CellBytes, RowBytes, sink)
		if err != nil {
			return err
		}
		if res.Err != nil {
			if sink.started {
				sink.finish("")
			} else {
				j.null()
			}
			j.k("error").obj().k("sqlstate").s(res.Err.Code).k("message").s(res.Err.Message).end()
		} else {
			sink.finish(res.Tag)
			j.k("has_more").bool(sink.reason == "rows")
		}
		j.end()
		return nil
	})
	if !started {
		if err != nil && strings.Contains(err.Error(), "out of range") {
			apiErr(w, 400, "bad_request", err.Error())
			return
		}
		s.sqlFail(w, err)
		return
	}
	bw.Flush()
}
