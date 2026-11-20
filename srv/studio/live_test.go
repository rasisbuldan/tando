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
