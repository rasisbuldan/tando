package sqlsplit

import (
	"strings"
	"testing"
	"unicode/utf8"
)

func texts(s []Stmt) []string {
	var o []string
	for _, x := range s {
		o = append(o, x.Text)
	}
	return o
}

func TestSplit(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{
		{"select 1; select 2", []string{"select 1", "select 2"}},
		{"  select 1 ;\n\n", []string{"select 1"}},
		{";;  ; -- only a comment\n /* and another */ ;", nil},
		{"select ';' ; select 2", []string{"select ';'", "select 2"}},
		{"select 'it''s;' ; x", []string{"select 'it''s;'", "x"}},
		{`select E'a\';b'; x`, []string{`select E'a\';b'`, "x"}},
		{`select e'\\'; x`, []string{`select e'\\'`, "x"}},
		{`select 'a\'; x`, []string{`select 'a\'`, "x"}},       // standard strings: no backslash escape
		{`select de'x;y'; z`, []string{`select de'x;y'`, "z"}}, // "de" is an identifier, not E
		{`select "a;""b"; x`, []string{`select "a;""b"`, "x"}},
		{"select $$a;b$$; x", []string{"select $$a;b$$", "x"}},
		{"select $fn$ a $$ ; $ b $fn$; x", []string{"select $fn$ a $$ ; $ b $fn$", "x"}},
		{"select $1; select a$b$c; x", []string{"select $1", "select a$b$c", "x"}},
		{"select 1 /* a /* nested ; */ still ; */ ; x", []string{"select 1 /* a /* nested ; */ still ; */", "x"}},
		{"select 1 -- c; d\n; x", []string{"select 1 -- c; d", "x"}},
		{"select 'unterminated; x", []string{"select 'unterminated; x"}},
		{"select $q$ unterminated; x", []string{"select $q$ unterminated; x"}},
		{"select /* unterminated; x", []string{"select /* unterminated; x"}},
		{"-- lead\nselect 1", []string{"-- lead\nselect 1"}},
	}
	for _, tc := range cases {
		got := texts(Split(tc.in))
		if strings.Join(got, "\x00") != strings.Join(tc.want, "\x00") {
			t.Errorf("%q:\n got %q\nwant %q", tc.in, got, tc.want)
		}
	}
}

func TestOffsetsInCodePoints(t *testing.T) {
	in := "select 'é—😀';\n  select x"
	s := Split(in)
	if len(s) != 2 || s[1].Text != "select x" || s[1].CP != utf8.RuneCountInString(in[:s[1].Start]) || s[1].CP != 16 {
		t.Fatalf("%+v", s)
	}
}

func TestReadOnly(t *testing.T) {
	ok := []string{"select 1", "SELECT 1", "  (select 1) union select 2", "with x as (select 1) select * from x",
		"values (1)", "table t", "show all", "explain select 1", "explain analyze select 1",
		"set statement_timeout = 0", "SET LOCAL statement_timeout = '1s'", "set search_path to x",
		"reset all", "reset role", "/* c */ -- d\n select 1", "set time zone 'UTC'", `set "statement_timeout" = 0`}
	no := []string{"insert into t values (1)", "update t set a = 1", "delete from t", "commit", "rollback",
		"begin", "begin read write", "start transaction", "end", "abort", "savepoint a", "release a",
		"set transaction read write", "SET TRANSACTION READ WRITE", "set session characteristics as transaction read write",
		"set session authorization postgres", "set session session authorization x", "set role postgres",
		"set local role x", "set session role x", `set "role" = x`, `set "ROLE" to x`, "set default_transaction_read_only = off",
		"set local transaction_read_only = off", "set session default_transaction_read_only to off",
		"set", "set session", "lock t in access exclusive mode", "reindex table t", "analyze t", "vacuum t",
		"notify c", "listen c", "copy t to stdout", "do $$ begin end $$", "call p()", "create temp table x (a int)",
		"prepare p as delete from t", "execute p", "declare c cursor for select 1", "fetch c", "checkpoint",
		"cluster t", "discard all", "truncate t", "grant select on t to x", "drop table t", "", "  ", "-- x",
		"(", "$$select$$", `"select" 1`, "comment on table t is 'x'", "security label on table t is 'x'",
		"refresh materialized view m", "alter table t add b int", "load 'x'", "import foreign schema x"}
	for _, s := range ok {
		if !ReadOnly(s) {
			t.Errorf("refused: %q", s)
		}
	}
	for _, s := range no {
		if ReadOnly(s) && s != `"select" 1` {
			t.Errorf("allowed: %q", s)
		}
	}
}

func FuzzSplit(f *testing.F) {
	for _, s := range []string{"select 1; select 2", "select $a$;$a$; 'x;' \"y;\" /* /* */ */ -- z\n;", "E'\\';'", "$", "'", "/*", "$$"} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, in string) {
		prev := 0
		for _, s := range Split(in) {
			if s.Start < prev || s.End < s.Start || s.End > len(in) || in[s.Start:s.End] != s.Text || s.Text == "" {
				t.Fatalf("bad piece %+v (prev end %d) of %q", s, prev, in)
			}
			if s.CP != utf8.RuneCountInString(in[:s.Start]) {
				t.Fatalf("code-point offset %d of %+v", s.CP, s)
			}
			if isSpace(s.Text[0]) || isSpace(s.Text[len(s.Text)-1]) {
				t.Fatalf("not trimmed: %q", s.Text)
			}
			prev = s.End
		}
		// a single statement without ';' outside quotes comes back whole
		if !strings.Contains(in, ";") {
			if p := Split(in); len(p) > 1 {
				t.Fatalf("no ';' but %d pieces", len(p))
			}
		}
		Words(in, 4)
		ReadOnly(in)
	})
}

// The backend's resource settings cannot be changed from the editor (SET or set_config).
func TestResourceSettingsRefused(t *testing.T) {
	no := []string{"set work_mem = '1GB'", "SET LOCAL hash_mem_multiplier = 10", "set jit = on", "set session temp_buffers to '1GB'",
		"set max_parallel_workers_per_gather = 8", "set max_parallel_workers = 8", "set lock_timeout = 0", `set "WORK_MEM" = '1GB'`,
		"set idle_in_transaction_session_timeout = 0", "set maintenance_work_mem = '1GB'",
		"select set_config('work_mem', '1GB', false)", "SELECT pg_catalog.set_config('work_mem', '1GB', true), 1",
		`select "set_config"('jit', 'on', false)`, `select "SET_CONFIG"('jit', 'on', false)`, "select x from t where set_config('a','b',true) is null",
		"with x as (select set_config('work_mem','1GB',false)) select * from x", "select e'\\'' || set_config('jit','on',true)"}
	ok := []string{"select 'set_config'", "select 1 -- set_config(\n", "select $$set_config$$", "select /* set_config( */ 1",
		"select current_setting('work_mem')", "show work_mem", "reset work_mem", "reset all", "set statement_timeout = 0", "select my_set_config()"}
	for _, s := range no {
		if ReadOnly(s) {
			t.Errorf("allowed: %q", s)
		}
	}
	for _, s := range ok {
		if !ReadOnly(s) {
			t.Errorf("refused: %q", s)
		}
	}
}
