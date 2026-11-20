package sqlsplit

import "testing"

// The scope guard's names: every way to write a system schema, table or catalog-reading function
// is refused; strings, comments and the app's own names are not.
func TestScope(t *testing.T) {
	no := map[string]string{ // statement: the name reported
		"select * from pg_class":                                            "pg_class",
		`select * from "pg_class"`:                                          "pg_class",
		"SELECT * FROM PG_CATALOG.pg_class":                                 "pg_catalog",
		"select * from pg_catalog /* . */ . -- x\n pg_class":                "pg_catalog",
		`select * from "PG_ROLES"`:                                          "PG_ROLES",
		"table pg_roles":                                                    "pg_roles",
		"select * from information_schema.tables":                           "information_schema",
		`select * from "information_schema"."columns"`:                      "information_schema",
		"select * from pg_toast.pg_toast_1259":                              "pg_toast",
		"select * from pg_temp.t":                                           "pg_temp",
		"select 1 from items where exists (select 1 from pg_stat_activity)": "pg_stat_activity",
		"select (select rolname from pg_roles limit 1)":                     "pg_roles",
		"values ((select count(*) from pg_class))":                          "pg_class",
		"select pg_get_userbyid(10)":                                        "pg_get_userbyid",
		"select pg_catalog.now()":                                           "pg_catalog",
		"select current_setting('work_mem')":                                "current_setting",
		"select has_table_privilege('t', 'select')":                         "has_table_privilege",
		"select HAS_SCHEMA_PRIVILEGE('public', 'usage')":                    "has_schema_privilege",
		"select to_regclass('pg_authid')":                                   "to_regclass",
		"select to_regrole('postgres')":                                     "to_regrole",
		"select pg_database_size(current_database())":                       "pg_database_size",
		"select obj_description(1259)":                                      "obj_description",
		"select col_description(1259, 1)":                                   "col_description",
		"select shobj_description(1, 'pg_database')":                        "shobj_description",
		"select format_type(23, null)":                                      "format_type",
		"select pg_relation_size('items')":                                  "pg_relation_size",
		"select * from pg_ls_dir('.')":                                      "pg_ls_dir",
		"select txid_current()":                                             "txid_current",
		"select lo_get(1)":                                                  "lo_get",
		"select loread(0, 1)":                                               "loread",
		"select 'pg_authid'::regclass::oid":                                 "regclass",
		"select 'x'::REGCLASS":                                              "regclass",
		`select 'x'::"regclass"`:                                            "regclass",
		"select cast('x' as regclass)":                                      "regclass",
		"select regclass 'pg_authid'":                                       "regclass",
		"select '{a}'::regclass[]":                                          "regclass",
		"select 'x'::_regclass":                                             "_regclass",
		"select 'int4'::regtype, 1":                                         "regtype",
		"select 'postgres'::regrole":                                        "regrole",
		"select 'public'::regnamespace":                                     "regnamespace",
		"select 'now'::regproc":                                             "regproc",
		"select 'now()'::regprocedure":                                      "regprocedure",
		"select '+'::regoper":                                               "regoper",
		"select '+(int,int)'::regoperator":                                  "regoperator",
		"select 'english'::regconfig":                                       "regconfig",
		"select 'simple'::regdictionary":                                    "regdictionary",
		"select '\"C\"'::regcollation":                                      "regcollation",
		"select regclassin('x')":                                            "regclassin",
		"select tableoid::regclass, * from items":                           "regclass",
		"select 1 operator(pg_catalog.+) 1":                                 "pg_catalog",
		"select table_to_xml('pg_authid', true, false, '')":                 "table_to_xml",
		"select schema_to_xml('pg_catalog', true, false, '')":               "schema_to_xml",
		"select database_to_xml(true, false, '')":                           "database_to_xml",
		"select null::pg_authid":                                            "pg_authid",
		"set local search_path = pg_catalog":                                "pg_catalog",
		"explain select * from pg_class":                                    "pg_class",
		"show all":                                                          "SHOW ALL",
		"SHOW /* x */ ALL":                                                  "SHOW ALL",
		"select row_security_active('t')":                                   "row_security_active",
		"select acldefault('r', 10)":                                        "acldefault",
		"select current_schemas(true)":                                      "current_schemas",
	}
	for s, want := range no {
		if name, why, at := Scope(s); name != want || why == "" || at < 0 || at > len(s) {
			t.Errorf("%q: got %q %q at %d, want %q", s, name, why, at, want)
		}
	}
	ok := []string{"select * from items", "select 'pg_class', $$pg_authid$$, E'pg_roles\\''",
		"select 1 -- pg_class\n", "select /* information_schema */ 1", "select now(), current_user, version(), current_database()",
		"select pg_sleep(1)", "select pg_typeof(1), pg_size_pretty(10::bigint), pg_column_size('x'::text)",
		"select pg_advisory_lock(1), pg_try_advisory_xact_lock(2)", "select pg_input_is_valid('1', 'int')",
		"select count(*), sum(qty) from orders group by 1", "select * from generate_series(1, 3)",
		"select upper(name), regexp_replace(name, 'a', 'b'), registered_at from customers", "select * from big_orders",
		"show work_mem", "set local search_path = public", "set search_path = 'pg_catalog'", "reset all",
		"select region, regular from t", "select haste_privilege, has_x from t", "select lobby from t",
		`select "my pg_ table" from t`, "explain analyze select * from orders", "select 1 \"show\", 2 all_"}
	for _, s := range ok {
		if name, why, _ := Scope(s); name != "" {
			t.Errorf("%q: refused %q (%s)", s, name, why)
		}
	}
	// the server must read strings as this package does: their setting cannot be changed
	for _, s := range []string{"set standard_conforming_strings = off", "SET LOCAL standard_conforming_strings TO off", "set backslash_quote = on"} {
		if ReadOnly(s) {
			t.Errorf("allowed: %q", s)
		}
	}
	// a table or a function: a call has its '(' next
	for s, want := range map[string]string{"select * from pg_class": "a system table", "select pg_ls_dir /* x */ ('.')": "a system function",
		`select "pg_ls_dir"('.')`: "a system function", `table "pg_roles"`: "a system table", "select * from pg_class(": "a system function"} {
		if _, why, _ := Scope(s); why != want {
			t.Errorf("%q: %q, want %q", s, why, want)
		}
	}
	// the offset is where the name is
	if _, _, at := Scope("select 1 from x, pg_class"); at != 17 {
		t.Errorf("offset %d", at)
	}
	if _, _, at := Scope(`select 1 from x, "pg_class"`); at != 17 {
		t.Errorf("offset of a quoted name %d", at)
	}
}

func TestExplainTarget(t *testing.T) {
	cases := map[string]string{
		"explain select 1":                             "select 1",
		"EXPLAIN ANALYZE select 1":                     "select 1",
		"explain analyse verbose select 1":             "select 1",
		"explain verbose select 1":                     "select 1",
		"explain (analyze, costs off) select 1":        "select 1",
		"explain (FORMAT 'json', analyze) (select 1)":  "(select 1)",
		"explain (format json)\n-- c\n select 1":       "select 1",
		"explain /* x */ (analyze) /* y */ select 1":   "select 1",
		"explain (select 1)":                           "(select 1)",
		"explain ( (select 1) )":                       "( (select 1) )",
		"explain with x as (select 1) select * from x": "with x as (select 1) select * from x",
		"explain values (1)":                           "values (1)",
		"explain table t":                              "table t",
		"explain analyze delete from t":                "delete from t",
		"explain":                                      "",
		"explain analyze":                              "",
		"explain (analyze":                             "",
		"explain (analyze (x)) select 1":               "",
		"select 1":                                     "",
		"explain (analyze) ":                           "",
	}
	for in, want := range cases {
		got, off := ExplainTarget(in)
		if got != want || (got != "" && in[off:] != got) {
			t.Errorf("%q: got %q at %d, want %q", in, got, off, want)
		}
	}
}

func FuzzScope(f *testing.F) {
	for _, s := range []string{"select * from pg_class", `select "pg_class"`, "explain (analyze) select 1", "'", "\"", "$a$", "explain ("} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, in string) {
		if name, _, at := Scope(in); name != "" && (at < 0 || at > len(in)) {
			t.Fatalf("offset %d of %d", at, len(in))
		}
		if s, off := ExplainTarget(in); s != "" && (off < 0 || off > len(in) || in[off:] != s) {
			t.Fatalf("target %q at %d", s, off)
		}
	})
}
