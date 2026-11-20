package studio

import (
	"bytes"

	"os"
	"strings"
	"tando/srv/studio/pgwire"
	"testing"
)

// The plan walker on plans PostgreSQL 16 printed (EXPLAIN (VERBOSE, FORMAT JSON), testdata/plans)
// for a demo app's tables (customers, items, orders, the view big_orders) and for statements that
// reach the catalogs through a view of the app's or a subplan.
func TestPlanScopeFixtures(t *testing.T) {
	want := map[string]string{ // fixture: the refused name ("" in scope)
		"own-join": "", "own-view": "", "own-cte": "", "own-funcs": "", "own-index": "",
		"sys-view":         "pg_catalog.pg_authid", // CREATE VIEW sneaky AS SELECT rolname FROM pg_roles
		"sys-view-setting": "current_setting",      // CREATE VIEW sneaky2 AS SELECT current_setting('work_mem')
		"sys-infoschema":   "pg_catalog.pg_class",  // information_schema.tables, expanded
		"sys-subplan":      "pg_catalog.pg_authid", // (SELECT rolname FROM pg_roles LIMIT 1), an InitPlan
		"sys-funcscan":     "pg_catalog.pg_get_keywords",
	}
	for f, w := range want {
		b, err := os.ReadFile("testdata/plans/" + f + ".json")
		if err != nil {
			t.Fatal(err)
		}
		name, why, err := planScope(b)
		if err != nil || name != w || (w != "" && why == "") {
			t.Errorf("%s: got %q %q %v, want %q", f, name, why, err, w)
		}
	}
}

// Fail closed: a plan the walker cannot read is a refusal, never a pass.
func TestPlanScopeFailsClosed(t *testing.T) {
	ok, err := os.ReadFile("testdata/plans/own-join.json")
	if err != nil {
		t.Fatal(err)
	}
	bad := map[string]string{
		"not JSON":              "Seq Scan on items",
		"cut":                   string(ok[:len(ok)/2]),
		"empty":                 "[]",
		"two plans":             `[{"Plan": {"Node Type": "Result"}}, {"Plan": {"Node Type": "Result"}}]`,
		"no Plan":               `[{"Query": {}}]`,
		"unknown node type":     strings.Replace(string(ok), `"Hash Join"`, `"Teleport Scan"`, 1),
		"no node type":          `[{"Plan": {"Output": ["1"]}}]`,
		"relation, no schema":   `[{"Plan": {"Node Type": "Seq Scan", "Relation Name": "items"}}]`,
		"relation not a string": `[{"Plan": {"Node Type": "Seq Scan", "Relation Name": 7, "Schema": "public"}}]`,
		"Plans not a list":      `[{"Plan": {"Node Type": "Result", "Plans": {"Node Type": "Result"}}}]`,
		"a child not a node":    `[{"Plan": {"Node Type": "Result", "Plans": ["Seq Scan"]}}]`,
		"too large":             `[{"Plan": {"Node Type": "Result", "Output": ["` + strings.Repeat("x", PlanBytes) + `"]}}]`,
		"too deep":              strings.Repeat(`{"Node Type": "Result", "Plans": [`, 300),
	}
	bad["too deep"] = `[{"Plan": ` + bad["too deep"] + `{"Node Type": "Result"}` + strings.Repeat(`]}`, 300) + `}]`
	for k, p := range bad {
		if name, _, err := planScope([]byte(p)); err == nil && name == "" {
			t.Errorf("%s: passed", k)
		}
	}
	// the structural checks: a system schema by any name, a function scan of a pg_ function
	sys := map[string]string{
		`[{"Plan": {"Node Type": "Seq Scan", "Relation Name": "x", "Schema": "pg_toast"}}]`:                                                                              "pg_toast.x",
		`[{"Plan": {"Node Type": "Seq Scan", "Relation Name": "x", "Schema": "pg_temp_3"}}]`:                                                                             "pg_temp_3.x",
		`[{"Plan": {"Node Type": "Seq Scan", "Relation Name": "x", "Schema": "information_schema"}}]`:                                                                    "information_schema.x",
		`[{"Plan": {"Node Type": "Index Only Scan", "Relation Name": "x", "Schema": "pg_catalog"}}]`:                                                                     "pg_catalog.x",
		`[{"Plan": {"Node Type": "Result", "Plans": [{"Node Type": "Limit", "Plans": [{"Node Type": "Foreign Scan", "Relation Name": "t", "Schema": "pg_catalog"}]}]}}]`: "pg_catalog.t",
		`[{"Plan": {"Node Type": "Function Scan", "Function Name": "pg_ls_dir", "Schema": "pg_catalog"}}]`:                                                               "pg_catalog.pg_ls_dir",
		`[{"Plan": {"Node Type": "Result", "Output": ["'x'::regclass"]}}]`:                                                                                               "regclass",
		`[{"Plan": {"Node Type": "Result", "One-Time Filter": "has_table_privilege('t', 'select')"}}]`:                                                                   "has_table_privilege",
	}
	for p, w := range sys {
		if name, _, err := planScope([]byte(p)); err != nil || name != w {
			t.Errorf("%s: got %q %v, want %q", p, name, err, w)
		}
	}
	// in scope: the app's schemas, generate_series (pg_catalog, a Function Scan), names in strings
	for _, p := range []string{
		`[{"Plan": {"Node Type": "Seq Scan", "Relation Name": "items", "Schema": "shop"}}]`,
		`[{"Plan": {"Node Type": "Function Scan", "Function Name": "generate_series", "Schema": "pg_catalog", "Function Call": "generate_series(1, 3)"}}]`,
		`[{"Plan": {"Node Type": "Result", "Output": ["'pg_class'::text", "pg_typeof(1)"]}}]`,
	} {
		if name, _, err := planScope([]byte(p)); err != nil || name != "" {
			t.Errorf("%s: refused %q %v", p, name, err)
		}
	}
}

// The plan half runs in the transaction, after the up-front checks, for each statement that has
// a plan (not SHOW, SET, RESET); a user's EXPLAIN gets the statement it explains planned; a
// refusal stops the batch there, with nothing of that statement run.
func TestPlanCheckInTheBatch(t *testing.T) {
	f := newFake(nil)
	f.plan = func(stmt string) step {
		if strings.Contains(stmt, "sneaky") {
			return planStep(`[{"Plan": {"Node Type": "Seq Scan", "Relation Name": "pg_authid", "Schema": "pg_catalog", "Alias": "pg_authid"}}]`)
		}
		return planStep(`[{"Plan": {"Node Type": "Result"}}]`)
	}
	s, _ := newStudio(t, f)
	q, _ := query(t, s, "set local search_path = x; show work_mem; select 1; explain (analyze, costs off) select 2; select * from sneaky; select 3")
	if q.Error == nil || q.Error.Stmt != 4 || q.Error.SQLState != "42501" || q.Error.Position != 0 ||
		q.Error.Message != "the studio only reads this app's own tables: pg_catalog.pg_authid is a system table" {
		t.Fatalf("%+v", q.Error)
	}
	f.mu.Lock()
	ex := strings.Join(f.explains, "|")
	f.mu.Unlock()
	if ex != "select 1|select 2|select * from sneaky" {
		t.Fatalf("explained: %q", ex)
	}
	for _, c := range f.Calls() {
		if strings.Contains(c, "sneaky") || strings.Contains(c, "select 3") {
			t.Fatalf("ran after the refusal: %q", f.Calls())
		}
	}
	// a plan that cannot be read: refused, not run
	f2 := newFake(nil)
	f2.plan = func(string) step { return planStep(`[{"Plan": {"Node Type": "Hyper Scan"}}]`) }
	q, _ = query(t, first(newStudio(t, f2)), "select 1")
	if q.Error == nil || q.Error.SQLState != "42501" || !strings.Contains(q.Error.Message, "could not check") || strings.Contains(strings.Join(f2.Calls(), "|"), "exec select 1") {
		t.Fatalf("%+v %q", q.Error, f2.Calls())
	}
	// EXPLAIN's own error is the statement's, at its place in the statement
	f3 := newFake(nil)
	f3.plan = func(stmt string) step {
		if !strings.Contains(stmt, "nope") {
			return planStep(`[{"Plan": {"Node Type": "Result"}}]`)
		}
		return step{res: pgwire.Result{Err: &pgwire.Error{Code: "42P01", Message: `relation "nope" does not exist`, Position: len(explainPrefix) + 15}}}
	}
	q, _ = query(t, first(newStudio(t, f3)), "select 1;\nselect * from nope")
	if q.Error == nil || q.Error.SQLState != "42P01" || q.Error.Position != 25 {
		t.Fatalf("%+v", q.Error)
	}
}

// The tables list and lookups are the studio's own SQL: no system schema, no switch to show one.
func TestCatalogHidesSystemSchemas(t *testing.T) {
	for _, q := range []string{tablesSQL, relSQL} {
		if !strings.Contains(q, "n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'") || strings.Contains(q, "$1::bool") {
			t.Errorf("%s", q)
		}
	}
}

func first(s *Studio, _ *bytes.Buffer) *Studio { return s }

// Browsing a view's rows: a view of the app's that reads a system table is refused (403, the
// scope message) by the same plan check, before its rows are read; a table is not planned.
func TestRowsOfAViewArePlanned(t *testing.T) {
	str := func(s string) *string { return &s }
	f := newFake(func(sql string) step {
		switch sql {
		case relSQL:
			return step{cols: []string{"oid", "kind", "est", "bytes", "comment"}, rows: [][]*string{{str("1"), str("v"), str("0"), str("0"), str("")}}}
		case colsSQL:
			return step{cols: make([]string, 9), rows: [][]*string{{str("rolname"), str("name"), str("19"), str("64"), str("f"), str(""), str(""), str(""), str("0")}}}
		}
		return step{res: pgwire.Result{Tag: "SELECT 0"}}
	})
	f.plan = func(stmt string) step {
		return planStep(`[{"Plan": {"Node Type": "Seq Scan", "Relation Name": "pg_authid", "Schema": "pg_catalog"}}]`)
	}
	s, _ := newStudio(t, f)
	w := do(s, call{path: "/api/rows", body: `{"schema":"public","name":"sys_v","limit":10}`})
	if w.Code != 403 || !strings.Contains(w.Body.String(), "pg_catalog.pg_authid is a system table") {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
	for _, c := range f.Calls() {
		if strings.Contains(c, `FROM "public"."sys_v"`) {
			t.Fatalf("the view's rows were read: %q", f.Calls())
		}
	}
	f.mu.Lock()
	ex := append([]string(nil), f.explains...)
	f.mu.Unlock()
	if len(ex) != 1 || ex[0] != `TABLE "public"."sys_v"` {
		t.Fatalf("%q", ex)
	}
}
