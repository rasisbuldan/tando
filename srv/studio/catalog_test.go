package studio

import (
	"bufio"
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"unicode/utf8"

	"tando/srv/studio/sqlsplit"
)

var hostile = []string{`a"b`, `x; drop table y; --`, `"`, `""`, `é—😀`, "tab\there", "new\nline", `$$`, `'`, `\`, `*/`, `--`}

func fixture() *relation {
	r := &relation{Schema: `sch"ema; --`, Name: `t"; DROP TABLE users; --`, Kind: "r"}
	for i, n := range hostile {
		c := column{Name: n, TypLen: 4, OID: 23}
		if i%3 == 0 {
			c.TypLen, c.OID = -1, 25
		}
		if i == 4 {
			c.OID, c.TypLen = 17, -1
		}
		if i == 0 {
			c.PK = 1
		}
		r.Cols = append(r.Cols, c)
	}
	return r
}

func TestQuoteIdent(t *testing.T) {
	for in, want := range map[string]string{`a`: `"a"`, `a"b`: `"a""b"`, `"`: `""""`, `x; drop`: `"x; drop"`} {
		if got := quoteIdent(in); got != want {
			t.Errorf("%q: %s", in, got)
		}
	}
}

func TestBuildRowsGolden(t *testing.T) {
	sql, params, bytea, err := buildRows(fixture(), rowsReq{Offset: 200, Limit: 100, Sort: `x; drop table y; --`, Desc: true})
	if err != nil {
		t.Fatal(err)
	}
	want := `SELECT left(("a""b")::text, 16385), "x; drop table y; --", """", left(("""""")::text, 16385), substring("é—😀" from 1 for 8193), "tab	here", left(("new
line")::text, 16385), "$$", "'", left(("\")::text, 16385), "*/", "--", octet_length("é—😀") FROM "sch""ema; --"."t""; DROP TABLE users; --" ORDER BY "x; drop table y; --" DESC NULLS LAST, "a""b" LIMIT $1 OFFSET $2`
	if sql != want {
		t.Fatalf("got\n%s\nwant\n%s", sql, want)
	}
	if string(params[0]) != "101" || string(params[1]) != "200" || bytea[4] != len(hostile) {
		t.Fatalf("%q %v", params, bytea)
	}
	if n := len(sqlsplit.Split(sql)); n != 1 {
		t.Fatalf("%d statements", n)
	}
	if _, _, _, err := buildRows(fixture(), rowsReq{Limit: 10, Sort: "no such column"}); err != errNotFound {
		t.Fatal("an unknown sort column must be refused")
	}
	for _, q := range []rowsReq{{Limit: 0}, {Limit: 501}, {Limit: 10, Offset: -1}} {
		if _, _, _, err := buildRows(fixture(), q); err == nil {
			t.Fatalf("%+v accepted", q)
		}
	}
	// no key: ctid for a table, nothing for a view
	r := &relation{Schema: "s", Name: "v", Kind: "r", Cols: []column{{Name: "a", TypLen: 4}}}
	if sql, _, _, _ := buildRows(r, rowsReq{Limit: 1}); !strings.Contains(sql, "ORDER BY ctid") {
		t.Fatal(sql)
	}
	r.Kind = "v"
	if sql, _, _, _ := buildRows(r, rowsReq{Limit: 1}); strings.Contains(sql, "ORDER BY") {
		t.Fatal(sql)
	}
}

// FuzzQuoteIdent: a quoted name reads back as itself (the splitter's reading of a quoted
// identifier, which is PostgreSQL's), and stays one word of one statement.
func FuzzQuoteIdent(f *testing.F) {
	for _, h := range hostile {
		f.Add(h)
	}
	f.Fuzz(func(t *testing.T, s string) {
		if strings.IndexByte(s, 0) >= 0 || !utf8.ValidString(s) {
			return
		}
		q := quoteIdent(s)
		w := sqlsplit.Words("select "+q+" x", 3)
		if len(w) != 3 || w[1] != s || w[2] != "x" {
			t.Fatalf("%q -> %s -> %q", s, q, w)
		}
		if n := len(sqlsplit.Split("select " + q + " from t; ")); n != 1 {
			t.Fatalf("%q: %d statements", s, n)
		}
	})
}

// FuzzBuildRows: any request gives an error or SQL whose quoted names are all the catalog's,
// one statement, values only as parameters.
func FuzzBuildRows(f *testing.F) {
	f.Add(`a"b`, 0, 10, true)
	f.Add("x; drop table y; --", 99, 500, false)
	f.Add("", -1, 0, false)
	known := map[string]bool{}
	fx := fixture()
	for _, c := range fx.Cols {
		known[c.Name] = true
	}
	known[fx.Schema], known[fx.Name] = true, true
	f.Fuzz(func(t *testing.T, sort string, off, lim int, desc bool) {
		sql, params, _, err := buildRows(fixture(), rowsReq{Sort: sort, Offset: off, Limit: lim, Desc: desc})
		if err != nil {
			return
		}
		if len(params) != 2 || len(sqlsplit.Split(sql)) != 1 {
			t.Fatalf("%q", sql)
		}
		// every "..." in the SQL is a catalog name
		for i := 0; i < len(sql); i++ {
			if sql[i] != '"' {
				continue
			}
			j := i + 1
			var b strings.Builder
			for j < len(sql) {
				if sql[j] == '"' {
					if j+1 < len(sql) && sql[j+1] == '"' {
						b.WriteByte('"')
						j += 2
						continue
					}
					break
				}
				b.WriteByte(sql[j])
				j++
			}
			if !known[b.String()] && b.String() != "(no columns)" {
				t.Fatalf("name %q is not the catalog's in %s", b.String(), sql)
			}
			i = j
		}
	})
}

func TestJSONWriter(t *testing.T) {
	var buf bytes.Buffer
	w := bufio.NewWriter(&buf)
	j := &jw{w: w}
	j.obj().k("a").s("<script>&\"\\\n\t\x00\x7f  é😀").k("b").b([]byte{'x', 0xff, 0xfe, 'y'}).k("c").arr().i(1).null().bool(true).aend().end()
	w.Flush()
	want := strings.ReplaceAll(`{"a":"Ru003cscriptRu003eRu0026R"RRRnRtRu0000Ru007fRu2028Ru2029é😀","b":"xRufffdRufffdy","c":[1,null,true]}`, "R", "\\")
	if buf.String() != want {
		t.Fatalf("got  %s\nwant %s", buf.String(), want)
	}
	var v map[string]any
	if err := json.Unmarshal(buf.Bytes(), &v); err != nil || v["a"] != "<script>&\"\\\n\t\x00\x7f  é😀" {
		t.Fatalf("%v %q", err, v["a"])
	}
}

func FuzzJSONString(f *testing.F) {
	f.Add([]byte("a\"<\xff "))
	f.Fuzz(func(t *testing.T, b []byte) {
		var buf bytes.Buffer
		w := bufio.NewWriter(&buf)
		(&jw{w: w}).b(b)
		w.Flush()
		var s string
		if err := json.Unmarshal(buf.Bytes(), &s); err != nil {
			t.Fatalf("%q -> %s: %v", b, buf.Bytes(), err)
		}
		if bytes.ContainsAny(buf.Bytes(), "<>&  ") || utf8.Valid(b) && s != string(b) {
			t.Fatalf("%q -> %s", b, buf.Bytes())
		}
	})
}

func TestParseArgsAndCred(t *testing.T) {
	ok := []string{"--sock", "/run/tando-studio/0123456789abcdef0123456789abcdef/s", "--app", "shop", "--host", "prod",
		"--admin", "vmadmin", "--port", "47123", "--idle", "30"}
	a, err := ParseArgs(ok)
	if err != nil || a.Cfg.Port != 47123 || a.Cfg.Idle.Minutes() != 30 || a.Cfg.StmtLimit != DefaultLimit {
		t.Fatal(err, a)
	}
	bad := [][]string{
		{"--sock", "/tmp/x/s"}, {"--app", "../x"}, {"--port", "80"}, {"--port", "99999"}, {"--idle", "0"}, {"--idle", "241"},
		{"--timeout", "31"}, {"--admin", "a b"}, {"--host", "x;y"}, {"--nope", "1"}, {"--app"},
	}
	for _, b := range bad {
		args := append(append([]string(nil), ok...), b...)
		if _, err := ParseArgs(args); err == nil {
			t.Errorf("%q accepted", b)
		}
	}
	var c Config
	if err := ParseCred([]byte("user=tando_shop\ndb=tando_shop\npassword=abc=def\n"), &c); err != nil || c.Password != "abc=def" {
		t.Fatal(err, c)
	}
	for _, b := range []string{"user=tando_shop\ndb=other\npassword=x\n", "user=postgres\ndb=postgres\npassword=x\n", "user=tando_shop\ndb=tando_shop\n"} {
		if err := ParseCred([]byte(b), &Config{}); err == nil {
			t.Errorf("%q accepted", b)
		}
	}
}
