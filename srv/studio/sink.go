package studio

import (
	"strconv"
	"unicode/utf8"

	"tando/srv/studio/pgwire"
)

// resultSink streams one statement's result into the response as JSON:
//
//	{"stmt":i,"offset":cp,"columns":[{"name","oid","type"}],"rows":[["1",null]],
//	 "command":"SELECT 2","trunc":[[row,col,full]],"truncated":false,"reason":""}
//
// Every value is a JSON string in PostgreSQL's text format (int8 and numeric keep their
// precision) or null. trunc lists the cells that were cut, with their full length in bytes
// (0: not known). reason: rows (the row limit) or bytes (the response's cap).
type resultSink struct {
	s       *Studio
	j       *jw
	stmt    int
	offset  int
	started bool
	ncols   int // columns shown (browse adds hidden octet_length columns after them)
	cols    []pgwire.Field
	rows    int
	max     int
	budget  *int // cell bytes left in the response
	trunc   [][3]int
	reason  string
	onStop  func()
	browse  bool
	bytea   map[int]int // browse: bytea column -> its hidden octet_length column
	rel     []column    // browse: the table's own columns (the query's are cut copies: left(c::text, n) is "left", text)
	unknown map[uint32]bool
	scratch []byte
}

func (r *resultSink) start() {
	if r.started {
		return
	}
	r.started = true
	r.j.obj().k("stmt").i(int64(r.stmt)).k("offset").i(int64(r.offset)).k("columns").arr()
	for i, f := range r.cols {
		if i >= r.ncols {
			break
		}
		if i < len(r.rel) {
			r.j.obj().k("name").s(r.rel[i].Name).k("oid").i(int64(r.rel[i].OID)).k("type").s(r.rel[i].Type).end()
			continue
		}
		r.j.obj().k("name").s(f.Name).k("oid").i(int64(f.TypeOID))
		if t := r.s.typeName(f.TypeOID); t != "" {
			r.j.k("type").s(t)
		} else if r.unknown != nil {
			r.unknown[f.TypeOID] = true
		}
		r.j.end()
	}
	r.j.aend().k("rows").arr()
}

func (r *resultSink) Columns(fs []pgwire.Field) error {
	r.cols = fs
	if r.ncols == 0 || r.ncols > len(fs) {
		r.ncols = len(fs)
	}
	if fs != nil {
		r.start()
	}
	return nil
}

func (r *resultSink) Row(cells [][]byte, full []int) error {
	if r.rows >= r.max {
		r.reason = "rows" // the one row past the limit (Execute asked for max+1)
		return nil
	}
	n := 0
	for _, c := range cells {
		n += len(c)
	}
	if n > *r.budget {
		r.reason = "bytes"
		if r.onStop != nil {
			r.onStop()
		}
		return pgwire.ErrStop
	}
	*r.budget -= n
	r.start()
	r.j.arr()
	for i, c := range cells {
		if i >= r.ncols {
			break
		}
		if c == nil {
			r.j.null()
			continue
		}
		f := full[i]
		if r.browse {
			c, f = r.browseCut(i, c, cells, f)
		}
		if f >= 0 && len(r.trunc) < 10000 {
			r.trunc = append(r.trunc, [3]int{r.rows, i, f})
		}
		r.j.b(c)
	}
	r.j.aend()
	r.rows++
	return nil
}

// browseCut: table browsing selects wide columns cut by SQL (left(c::text, 16385), a bytea's
// first 8193 bytes): one character or byte more than shown means the value was cut
func (r *resultSink) browseCut(i int, c []byte, cells [][]byte, f int) ([]byte, int) {
	if x, ok := r.bytea[i]; ok {
		if len(c) > 2+2*BrowseBytea { // \x + hex
			n, _ := strconv.Atoi(string(cells[x]))
			return c[:2+2*BrowseBytea], n
		}
		return c, f
	}
	if r.cols[i].TypLen == -1 && utf8.RuneCount(c) > BrowseChars {
		k := 0
		for j := 0; j < BrowseChars; j++ {
			_, n := utf8.DecodeRune(c[k:])
			k += n
		}
		return c[:k], 0
	}
	return c, f
}

// finish closes the result object (a statement without columns gets one here)
func (r *resultSink) finish(tag string) {
	r.start()
	r.j.aend().k("command").s(tag).k("trunc").arr()
	for _, t := range r.trunc {
		r.j.arr().i(int64(t[0])).i(int64(t[1])).i(int64(t[2])).aend()
	}
	r.j.aend().k("truncated").bool(r.reason != "").k("reason").s(r.reason).end()
}

// collect keeps a small result in memory (the catalog queries)
type collect struct {
	rows [][]*string
}

func (c *collect) Columns([]pgwire.Field) error { return nil }
func (c *collect) Row(cells [][]byte, _ []int) error {
	if len(c.rows) > 5000 {
		return pgwire.ErrStop
	}
	row := make([]*string, len(cells))
	for i, x := range cells {
		if x != nil {
			v := string(x)
			row[i] = &v
		}
	}
	c.rows = append(c.rows, row)
	return nil
}

func str(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

// typeName: format_type of the common types, then what the session learned
func (s *Studio) typeName(oid uint32) string {
	if t, ok := builtinTypes[oid]; ok {
		return t
	}
	if v, ok := s.types.Load(oid); ok {
		return v.(string)
	}
	return ""
}

var builtinTypes = map[uint32]string{16: "boolean", 17: "bytea", 18: "\"char\"", 19: "name", 20: "bigint",
	21: "smallint", 23: "integer", 25: "text", 26: "oid", 114: "json", 142: "xml", 700: "real",
	701: "double precision", 1042: "character", 1043: "character varying", 1082: "date",
	1083: "time without time zone", 1114: "timestamp without time zone", 1184: "timestamp with time zone",
	1186: "interval", 1266: "time with time zone", 1700: "numeric", 2950: "uuid", 3802: "jsonb",
	1000: "boolean[]", 1007: "integer[]", 1016: "bigint[]", 1009: "text[]", 869: "inet", 650: "cidr",
	829: "macaddr", 1560: "bit", 1562: "bit varying", 3614: "tsvector", 2249: "record", 2278: "void",
	705: "unknown"}
