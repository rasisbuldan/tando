package pgwire

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

// TestLive runs against a real PostgreSQL when PGWIRE_LIVE is set to "addr user database"
// and PGWIRE_LIVE_PW to the password (test/e2e-studio.sh runs this test binary on the test
// server as the app's role; by hand: a postgres container). Skipped otherwise.
func TestLive(t *testing.T) {
	spec := strings.Fields(os.Getenv("PGWIRE_LIVE"))
	if len(spec) != 3 {
		t.Skip("PGWIRE_LIVE not set")
	}
	cfg := Config{Addr: spec[0], User: spec[1], Database: spec[2], Password: os.Getenv("PGWIRE_LIVE_PW"),
		Params: [][2]string{{"application_name", "pgwire live test"}, {"client_encoding", "UTF8"},
			{"default_transaction_read_only", "on"}, {"statement_timeout", "30s"}}}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	c, err := Connect(ctx, cfg)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer c.Close()
	if c.Param("server_version") == "" || c.TxStatus() != 'I' || c.pid == 0 {
		t.Fatalf("after login: version %q tx %c pid %d", c.Param("server_version"), c.TxStatus(), c.pid)
	}
	t.Run("wrong password", func(t *testing.T) {
		bad := cfg
		bad.Password = "not-the-password"
		_, err := Connect(ctx, bad)
		if e, ok := err.(*Error); !ok || e.Code != "28P01" {
			t.Fatalf("want 28P01, got %v", err)
		}
	})
	t.Run("rows, NULL, empty, cut cells, params", func(t *testing.T) {
		s := &rec{}
		r, err := c.Exec("SELECT $1::text AS a, NULL AS b, '' AS c, repeat('x', 100000) AS d", [][]byte{[]byte("é<&>")}, 0, 1000, 1<<20, s)
		if err != nil || r.Err != nil {
			t.Fatal(err, r.Err)
		}
		if r.Tag != "SELECT 1" || len(s.cols) != 4 || s.cols[3].TypeOID != 25 || len(s.rows) != 1 {
			t.Fatalf("%+v %+v %d", r, s.cols, len(s.rows))
		}
		row := s.rows[0]
		if row[0] != "é<&>" || row[1] != "\x00NULL" || row[2] != "" || len(row[3]) != 1000 || s.full[0][3] != 100000 {
			t.Fatalf("row %q full %v", row, s.full[0])
		}
	})
	t.Run("row limit suspends the portal", func(t *testing.T) {
		s := &rec{}
		r, err := c.Exec("SELECT generate_series(1, 5000000)", nil, 1001, 64<<10, 1<<20, s)
		if err != nil || r.Err != nil || !r.Suspended || len(s.rows) != 1001 {
			t.Fatalf("%v %+v rows %d", err, r, len(s.rows))
		}
	})
	t.Run("two commands in one Parse are refused", func(t *testing.T) {
		r, err := c.Exec("SELECT 1; SELECT 2", nil, 0, 100, 1000, &rec{})
		if err != nil || r.Err == nil || r.Err.Code != "42601" {
			t.Fatalf("%v %+v", err, r.Err)
		}
	})
	t.Run("error position and notice", func(t *testing.T) {
		r, err := c.Exec("SELECT nosuchcol FROM pg_class", nil, 0, 100, 1000, &rec{})
		if err != nil || r.Err == nil || r.Err.Code != "42703" || r.Err.Position != 8 {
			t.Fatalf("%v %+v", err, r.Err)
		}
		r, err = c.Exec("DO $$ BEGIN RAISE NOTICE 'hello %', 1; END $$", nil, 0, 100, 1000, &rec{})
		if err != nil || len(r.Notices) != 1 || r.Notices[0].Message != "hello 1" {
			t.Fatalf("%v %+v", err, r)
		}
	})
	t.Run("simple query and transaction status", func(t *testing.T) {
		if err := c.Simple("BEGIN READ ONLY; SELECT 1"); err != nil || c.TxStatus() != 'T' {
			t.Fatal(err, c.TxStatus())
		}
		r, err := c.Exec("SET TRANSACTION READ WRITE", nil, 0, 100, 1000, &rec{})
		if err != nil || r.Err == nil || r.Err.Code != "25001" || c.TxStatus() != 'E' {
			t.Fatalf("snapshot taken: SET TRANSACTION READ WRITE must fail: %v %+v %c", err, r.Err, c.TxStatus())
		}
		if err := c.Simple("ROLLBACK"); err != nil || c.TxStatus() != 'I' {
			t.Fatal(err)
		}
		if err := c.Simple("DISCARD ALL"); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("copy is refused and the session stays usable", func(t *testing.T) {
		r, err := c.Exec("COPY (SELECT 1) TO STDOUT", nil, 0, 100, 1000, &rec{})
		if err != nil || r.Err == nil || !r.Copy {
			t.Fatalf("copy out: %v %+v", err, r)
		}
		if err := c.Simple("BEGIN READ WRITE; CREATE TEMP TABLE pgwire_t (a int)"); err != nil {
			t.Fatal(err)
		}
		r, err = c.Exec("COPY pgwire_t FROM STDIN", nil, 0, 100, 1000, &rec{})
		if err != nil || r.Err == nil || !r.Copy {
			t.Fatalf("copy in: %v %+v", err, r)
		}
		if err := c.Simple("ROLLBACK"); err != nil {
			t.Fatal(err)
		}
		s := &rec{}
		r, err = c.Exec("SELECT 42", nil, 0, 100, 1000, s)
		if err != nil || r.Err != nil || s.rows[0][0] != "42" {
			t.Fatalf("after copy: %v %+v", err, r)
		}
	})
	t.Run("cancel", func(t *testing.T) {
		done := make(chan Result, 1)
		go func() {
			r, _ := c.Exec("SELECT pg_sleep(20)", nil, 0, 100, 1000, &rec{})
			done <- r
		}()
		time.Sleep(300 * time.Millisecond)
		start := time.Now()
		if err := c.Cancel(ctx); err != nil {
			t.Fatal(err)
		}
		select {
		case r := <-done:
			if r.Err == nil || r.Err.Code != "57014" || time.Since(start) > 2*time.Second {
				t.Fatalf("%+v after %v", r.Err, time.Since(start))
			}
		case <-time.After(5 * time.Second):
			t.Fatal("cancel did not stop the statement")
		}
	})
}

// rec records a result; a NULL cell is "\x00NULL"
type rec struct {
	cols []Field
	rows [][]string
	full [][]int
	stop int
}

func (r *rec) Columns(f []Field) error { r.cols = f; return nil }
func (r *rec) Row(c [][]byte, full []int) error {
	row := make([]string, len(c))
	for i, x := range c {
		if x == nil {
			row[i] = "\x00NULL"
		} else {
			row[i] = string(x)
		}
	}
	r.rows = append(r.rows, row)
	r.full = append(r.full, append([]int(nil), full...))
	if r.stop > 0 && len(r.rows) >= r.stop {
		return ErrStop
	}
	return nil
}
