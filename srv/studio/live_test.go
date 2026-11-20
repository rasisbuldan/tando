package studio

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"strings"
	"testing"
	"time"

	"tando/srv/studio/pgwire"
)

// TestLiveReadOnly: the studio against a real PostgreSQL (PGWIRE_LIVE="addr role database",
// PGWIRE_LIVE_PW; the role must own the database). It makes a table with a plain session, sends
// every bypass attempt through the studio's API and checks the table is unchanged. Skipped
// without the variables (test/e2e-studio.sh runs the same attempts through the real ssh forward
// and checks as the postgres superuser).
func TestLiveReadOnly(t *testing.T) {
	spec := strings.Fields(os.Getenv("PGWIRE_LIVE"))
	if len(spec) != 3 {
		t.Skip("PGWIRE_LIVE not set")
	}
	pw := os.Getenv("PGWIRE_LIVE_PW")
	ctx := context.Background()
	adm, err := pgwire.Connect(ctx, pgwire.Config{Addr: spec[0], User: spec[1], Database: spec[2], Password: pw})
	if err != nil {
		t.Fatal(err)
	}
	defer adm.Close()
	if err := adm.Simple(`DROP TABLE IF EXISTS studio_live; DROP SEQUENCE IF EXISTS studio_seq;
		CREATE TABLE studio_live (id int PRIMARY KEY, v text); INSERT INTO studio_live VALUES (1, 'one'), (2, 'two');
		CREATE SEQUENCE studio_seq`); err != nil {
		t.Fatal(err)
	}
	snapshot := func() string {
		c := &collect{}
		r, err := adm.Exec("SELECT string_agg(id || '=' || v, ',' ORDER BY id) || ' seq=' || (SELECT last_value FROM studio_seq) FROM studio_live", nil, 0, 1000, 1000, c)
		if err != nil || r.Err != nil {
			t.Fatal(err, r.Err)
		}
		return str(c.rows[0][0])
	}
	before := snapshot()
	s, err := New(ctx, Config{App: "x", Host: "h", Admin: "a", Role: spec[1], Database: spec[2], Password: pw,
		Port: port, Idle: time.Hour, StmtLimit: 3 * time.Second, PGAddr: spec[0], Out: io.Discard, Log: io.Discard})
	if err != nil {
		t.Fatal(err)
	}
	run := func(sql string) qresp {
		b, _ := json.Marshal(map[string]any{"id": "q", "sql": sql})
		w := do(s, call{path: "/api/query", body: string(b)})
		var q qresp
		if err := json.Unmarshal(w.Body.Bytes(), &q); err != nil {
			t.Fatalf("%q: %d %s", sql, w.Code, w.Body)
		}
		return q
	}
	attacks := []string{
		"INSERT INTO studio_live VALUES (3, 'x')",
		"COMMIT; INSERT INTO studio_live VALUES (3, 'x')",
		"BEGIN READ WRITE; INSERT INTO studio_live VALUES (3, 'x')",
		"SET TRANSACTION READ WRITE; DELETE FROM studio_live",
		"SET TRANSACTION READ WRITE; DELETE FROM studio_live; COMMIT",
		"SET LOCAL transaction_read_only = off; UPDATE studio_live SET v = 'x'; COMMIT",
		"COMMIT; SET TRANSACTION READ WRITE; DELETE FROM studio_live",
		"SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE; COMMIT; DELETE FROM studio_live",
		"SET default_transaction_read_only = off; COMMIT; DELETE FROM studio_live",
		"SELECT set_config('transaction_read_only', 'off', true); DELETE FROM studio_live",
		"SELECT set_config('default_transaction_read_only', 'off', false)",
		"DELETE FROM studio_live",
		"WITH d AS (DELETE FROM studio_live RETURNING *) SELECT * FROM d",
		"EXPLAIN ANALYZE DELETE FROM studio_live",
		"SELECT nextval('studio_seq')",
		"SELECT setval('studio_seq', 99)",
		"CREATE TEMP TABLE tt (a int)",
		"SELECT * INTO studio_new FROM studio_live",
		"SELECT * FROM studio_live FOR UPDATE",
		"COPY studio_live TO STDOUT",
		"DO $$ BEGIN DELETE FROM studio_live; COMMIT; END $$",
		"LOCK studio_live IN ACCESS EXCLUSIVE MODE",
		"VACUUM studio_live",
		"SELECT lo_create(0)",
		"SELECT pg_advisory_lock(42)", // allowed; released by DISCARD ALL (checked below)
	}
	for _, a := range attacks {
		q := run(a)
		if a != "SELECT pg_advisory_lock(42)" && a != "SELECT set_config('default_transaction_read_only', 'off', false)" && q.Error == nil {
			t.Errorf("%q: no error", a)
		}
		// the next request on the same connection must still be read-only
		if q := run("DELETE FROM studio_live"); q.Error == nil {
			t.Errorf("after %q: a DELETE got through", a)
		}
		q = run("SELECT 1")
		if q.Error != nil {
			t.Errorf("after %q: the session is broken: %+v", a, q.Error)
		}
	}
	// the advisory lock did not outlive its request (DISCARD ALL)
	c := &collect{}
	if r, err := adm.Exec("SELECT pg_try_advisory_lock(42)", nil, 0, 100, 100, c); err != nil || r.Err != nil || str(c.rows[0][0]) != "t" {
		t.Errorf("advisory lock still held: %v %v %v", err, r.Err, c.rows)
	}
	adm.Simple("SELECT pg_advisory_unlock_all()")
	if after := snapshot(); after != before {
		t.Fatalf("the data changed: %q -> %q", before, after)
	}
	// the studio's clock stops what the GUC was told not to
	t0 := time.Now()
	q := run("SET statement_timeout = 0; SELECT pg_sleep(10)")
	if q.Error == nil || q.Error.SQLState != "57014" || time.Since(t0) > 6*time.Second {
		t.Fatalf("clock: %+v after %v", q.Error, time.Since(t0))
	}
	if q := run("SELECT 1"); q.Error != nil {
		t.Fatalf("after the clock: %+v", q.Error)
	}
}

// TestLiveScope: the scope guard against a real PostgreSQL (the same variables as
// TestLiveReadOnly): every way to reach a system table is refused before it runs, with the
// guard's code (42501) or, for a refusal older than the guard, its own (25006: U&; 0A000: another
// database); the app's own tables, views and everyday functions work. It makes its own objects
// (scope_*) and drops them at the end.
func TestLiveScope(t *testing.T) {
	spec := strings.Fields(os.Getenv("PGWIRE_LIVE"))
	if len(spec) != 3 {
		t.Skip("PGWIRE_LIVE not set")
	}
	pw := os.Getenv("PGWIRE_LIVE_PW")
	ctx := context.Background()
	adm, err := pgwire.Connect(ctx, pgwire.Config{Addr: spec[0], User: spec[1], Database: spec[2], Password: pw})
	if err != nil {
		t.Fatal(err)
	}
	defer adm.Close()
	drop := `DROP VIEW IF EXISTS scope_v, scope_set, scope_ok, scope_fs; DROP FUNCTION IF EXISTS scope_f();
		DROP TABLE IF EXISTS scope_orders, scope_items; DROP SEQUENCE IF EXISTS scope_seq`
	if err := adm.Simple(drop + `;
		CREATE TABLE scope_items (id int PRIMARY KEY, name text, price numeric);
		CREATE TABLE scope_orders (id int PRIMARY KEY, item_id int REFERENCES scope_items, qty int);
		INSERT INTO scope_items SELECT i, 'item ' || i, i FROM generate_series(1, 50) i;
		INSERT INTO scope_orders SELECT i, 1 + i % 50, i % 5 FROM generate_series(1, 500) i;
		CREATE VIEW scope_ok AS SELECT * FROM scope_orders WHERE qty > 3;
		CREATE VIEW scope_v AS SELECT rolname FROM pg_roles;
		CREATE VIEW scope_set AS SELECT current_setting('work_mem') AS w;
		CREATE VIEW scope_fs AS SELECT * FROM pg_get_keywords() AS f;
		CREATE FUNCTION scope_f() RETURNS SETOF text LANGUAGE sql AS 'SELECT rolname::text FROM pg_roles';
		CREATE SEQUENCE scope_seq`); err != nil {
		t.Fatal(err)
	}
	defer adm.Simple(drop)
	s, err := New(ctx, Config{App: "x", Host: "h", Admin: "a", Role: spec[1], Database: spec[2], Password: pw,
		Port: port, Idle: time.Hour, StmtLimit: 3 * time.Second, PGAddr: spec[0], Out: io.Discard, Log: io.Discard})
	if err != nil {
		t.Fatal(err)
	}
	run := func(sql string) qresp {
		b, _ := json.Marshal(map[string]any{"id": "q", "sql": sql})
		w := do(s, call{path: "/api/query", body: string(b)})
		var q qresp
		if err := json.Unmarshal(w.Body.Bytes(), &q); err != nil {
			t.Fatalf("%q: %d %s", sql, w.Code, w.Body)
		}
		return q
	}
	refused := map[string]string{ // statement: the code it must be refused with
		"SELECT * FROM pg_class":                                                        "42501",
		`SELECT * FROM "pg_class"`:                                                      "42501",
		"SELECT * FROM PG_CATALOG.pg_class":                                             "42501",
		"SELECT * FROM pg_catalog /* x */ . pg_class":                                   "42501",
		"SELECT * FROM pg_catalog\n-- c\n.\tpg_class":                                   "42501",
		`SELECT * FROM U&"pg\005fclass"`:                                                "25006",
		"WITH x AS (SELECT * FROM pg_roles) SELECT * FROM x":                            "42501",
		"SELECT * FROM (SELECT * FROM pg_roles) s":                                      "42501",
		"SELECT * FROM scope_items i, LATERAL (SELECT rolname FROM pg_roles LIMIT 1) r": "42501",
		"SELECT name FROM scope_items UNION SELECT rolname FROM pg_roles":               "42501",
		"SELECT 1 WHERE EXISTS (SELECT 1 FROM pg_stat_activity)":                        "42501",
		"TABLE pg_roles": "42501",
		"SELECT * FROM information_schema.tables":                             "42501",
		`SELECT * FROM "information_schema"."tables"`:                         "42501",
		"SELECT (SELECT rolname FROM pg_roles LIMIT 1)":                       "42501",
		"SELECT pg_get_userbyid(10)":                                          "42501",
		"SELECT current_setting('work_mem')":                                  "42501",
		"SELECT has_table_privilege('scope_items', 'select')":                 "42501",
		"SELECT to_regclass('pg_authid')":                                     "42501",
		"SELECT pg_database_size(current_database())":                         "42501",
		"SELECT obj_description(1259)":                                        "42501",
		"SELECT pg_relation_size('scope_items')":                              "42501",
		"SELECT * FROM pg_ls_dir('.')":                                        "42501",
		"SELECT txid_current()":                                               "42501",
		"SELECT lo_get(1)":                                                    "42501",
		"SELECT 'pg_authid'::regclass::oid":                                   "42501",
		"SELECT CAST('x' AS regclass)":                                        "42501",
		"SELECT regclass 'pg_authid'":                                         "42501",
		"SELECT '{pg_authid}'::regclass[]":                                    "42501",
		"SELECT 1 OPERATOR(pg_catalog.+) 1":                                   "42501",
		"SELECT table_to_xml('pg_authid', true, false, '')":                   "42501",
		"SELECT schema_to_xml('pg_catalog', true, false, '')":                 "42501",
		"SELECT NULL::pg_authid":                                              "42501",
		"SELECT * FROM scope_v":                                               "42501", // a view of the app's over pg_roles: the plan
		"SELECT * FROM scope_set":                                             "42501", // a view calling current_setting: the plan's Output
		"SELECT * FROM scope_fs":                                              "42501", // a view over pg_get_keywords(): the plan's Function Scan
		"SELECT o.* FROM scope_ok o JOIN scope_v v ON true":                   "42501",
		"SET LOCAL search_path = pg_catalog; SELECT * FROM pg_class":          "42501",
		"SET LOCAL search_path = 'information_schema'; SELECT * FROM tables":  "42501", // the plan: pg_catalog.pg_class
		"SET LOCAL search_path = 'information_schema'; SELECT * FROM columns": "42501",
		"SELECT * FROM pg_temp.x":                                             "42501",
		"SELECT * FROM pg_toast.pg_toast_1259":                                "42501",
		"EXPLAIN SELECT * FROM pg_class":                                      "42501",
		"EXPLAIN SELECT * FROM scope_v":                                       "42501",
		"EXPLAIN (ANALYZE) SELECT * FROM scope_v":                             "42501",
		"EXPLAIN ANALYZE VERBOSE SELECT * FROM scope_v":                       "42501",
		"EXPLAIN (ANALYZE, FORMAT JSON) (SELECT * FROM scope_v)":              "42501",
		"EXPLAIN (SELECT * FROM scope_v)":                                     "42501",
		"VALUES ((SELECT count(*) FROM pg_class))":                            "42501",
		"WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r WHERE n < 3) SELECT * FROM r, scope_v": "42501",
		"SELECT tableoid::regclass, * FROM scope_items":                                                        "42501",
		"SELECT * FROM scope_items, pg_class":                                                                  "42501",
		`\d`:                                                                                                   "25006",
		"SET standard_conforming_strings = off; SELECT 1":                                                      "25006",
		"SHOW ALL":                              "42501",
		"SELECT * FROM other_db.public.secrets": "0A000", // another database: PostgreSQL refuses it (cross-database reference)
	}
	for sql, code := range refused {
		q := run(sql)
		if q.Error == nil || q.Error.SQLState != code {
			t.Errorf("%q: want %s, got %+v (%d results)", sql, code, q.Error, len(q.Results))
			continue
		}
		if code == "42501" && !strings.HasPrefix(q.Error.Message, "the studio only reads this app's own tables: ") &&
			!strings.HasPrefix(q.Error.Message, "the studio could not check") {
			t.Errorf("%q: message %q", sql, q.Error.Message)
		}
		if code == "42501" && strings.Contains(sql, "pg_class") && !strings.Contains(sql, "SET") && !strings.Contains(q.Error.Message, "pg_") {
			t.Errorf("%q: the message does not name the relation: %q", sql, q.Error.Message)
		}
	}
	// the plan names the relation and where the statement names it
	if q := run("SELECT 1;\nSELECT * FROM scope_v"); q.Error == nil || q.Error.Stmt != 1 ||
		q.Error.Message != "the studio only reads this app's own tables: pg_catalog.pg_authid is a system table" || len(q.Results) != 1 {
		t.Errorf("view: %+v", q.Error)
	}
	if q := run("SET LOCAL search_path = 'information_schema'; SELECT 1 FROM  tables"); q.Error == nil || q.Error.Position != 0 {
		t.Errorf("information_schema.tables: %+v", q.Error)
	}
	if q := run("select 1; select  * from pg_class"); q.Error == nil || q.Error.Position != 26 {
		t.Errorf("position: %+v", q.Error)
	}
	if q := run("EXPLAIN (COSTS OFF) SELECT * FROM scope_itemz"); q.Error == nil || q.Error.SQLState != "42P01" || q.Error.Position != 35 {
		t.Errorf("an error in an explained statement keeps its place: %+v", q.Error)
	}
	ok := []string{"SELECT * FROM scope_items", "SELECT count(*) FROM scope_orders",
		"SELECT i.name, sum(o.qty) FROM scope_orders o JOIN scope_items i ON i.id = o.item_id GROUP BY 1 ORDER BY 2 DESC",
		"SELECT * FROM scope_ok", "TABLE scope_items", "VALUES (1), (2)", "SELECT last_value FROM scope_seq",
		"SELECT * FROM scope_f()", // a function of the app's that reads a catalog: the documented limit
		"EXPLAIN SELECT * FROM scope_items", "EXPLAIN ANALYZE SELECT count(*) FROM scope_orders",
		"EXPLAIN (ANALYZE, COSTS OFF) SELECT * FROM scope_ok",
		"SELECT now(), current_user, current_database(), version(), pg_typeof(1), pg_size_pretty(1024::bigint)",
		"SELECT upper(name), length(name), substring(name from 2 for 3), to_char(now(), 'YYYY'), date_trunc('day', now()) FROM scope_items",
		"SELECT jsonb_build_object('a', 1), json_agg(i) FROM scope_items i",
		"SELECT * FROM generate_series(1, 3) g, LATERAL (SELECT * FROM scope_items WHERE id = g) x",
		"WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r WHERE n < 3) SELECT * FROM r",
		"SELECT 'pg_class', $$pg_authid$$ -- pg_roles\n", "SHOW work_mem", "SET LOCAL search_path = public; SELECT count(*) FROM scope_items",
		"SELECT pg_sleep(0)", "SELECT 1 WHERE EXISTS (SELECT 1 FROM scope_items)", "SELECT name FROM scope_items UNION SELECT 'x'",
	}
	for _, sql := range ok {
		if q := run(sql); q.Error != nil {
			t.Errorf("%q: refused: %+v", sql, q.Error)
		}
	}
}
