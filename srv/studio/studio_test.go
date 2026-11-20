package studio

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"tando/srv/studio/pgwire"
)

// ---- a fake PostgreSQL session that records every call ---------------------------------------

type step struct {
	cols  []string
	rows  [][]*string
	res   pgwire.Result
	tx    byte          // status after the statement (0: unchanged)
	block chan struct{} // the statement runs until this closes (or a cancel arrives)
	deaf  bool          // a cancel does not stop it (only Kill does)
}

type fakeDB struct {
	mu      sync.Mutex
	calls   []string
	tx      byte
	script  func(sql string) step
	cancel  chan struct{}
	killed  chan struct{}
	cancels int
	slots   []string // the answer to slotsSQL
}

func newFake(script func(string) step) *fakeDB {
	return &fakeDB{tx: 'I', script: script, cancel: make(chan struct{}, 10), killed: make(chan struct{})}
}

func (f *fakeDB) log(s string) { f.mu.Lock(); f.calls = append(f.calls, s); f.mu.Unlock() }
func (f *fakeDB) Calls() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.calls...)
}

func (f *fakeDB) Simple(sql string) error {
	f.log("simple " + sql)
	f.mu.Lock()
	defer f.mu.Unlock()
	switch sql {
	case "BEGIN READ ONLY; SELECT 1":
		f.tx = 'T'
	case "ROLLBACK":
		f.tx = 'I'
	}
	return nil
}

func (f *fakeDB) Exec(sql string, params [][]byte, maxRows int32, cellCap, rowCap int, sink pgwire.Sink) (pgwire.Result, error) {
	if sql == slotsSQL { // the connection count at dial (not logged: the tests compare batches)
		sink.Columns(make([]pgwire.Field, 4))
		f.mu.Lock()
		row := f.slots
		f.mu.Unlock()
		if row == nil {
			row = []string{"1", "10", "3", "17"}
		}
		sink.Row([][]byte{[]byte(row[0]), []byte(row[1]), []byte(row[2]), []byte(row[3])}, []int{-1, -1, -1, -1})
		return pgwire.Result{Tag: "SELECT 1"}, nil
	}
	f.log("exec " + sql)
	st := step{res: pgwire.Result{Tag: "SELECT 0"}}
	if f.script != nil {
		st = f.script(sql)
	}
	if st.block != nil {
		select {
		case <-st.block:
		case <-f.cancel:
			if !st.deaf {
				f.mu.Lock()
				f.tx = 'E'
				f.mu.Unlock()
				return pgwire.Result{Err: &pgwire.Error{Code: "57014", Message: "canceling statement due to user request"}}, nil
			}
			<-f.killed
			return pgwire.Result{}, io.ErrClosedPipe
		case <-f.killed:
			return pgwire.Result{}, io.ErrClosedPipe
		}
	}
	if st.cols != nil {
		fs := make([]pgwire.Field, len(st.cols))
		for i, c := range st.cols {
			fs[i] = pgwire.Field{Name: c, TypeOID: 25, TypLen: -1}
		}
		sink.Columns(fs)
		for _, r := range st.rows {
			cells := make([][]byte, len(r))
			full := make([]int, len(r))
			for i, c := range r {
				full[i] = -1
				if c != nil {
					cells[i] = []byte(*c)
				}
			}
			if sink.Row(cells, full) == pgwire.ErrStop {
				st.res.Stopped = true
				break
			}
		}
	} else {
		sink.Columns(nil)
	}
	f.mu.Lock()
	if st.tx != 0 {
		f.tx = st.tx
	} else if st.res.Err != nil {
		f.tx = 'E'
	}
	f.mu.Unlock()
	return st.res, nil
}

func (f *fakeDB) TxStatus() byte { f.mu.Lock(); defer f.mu.Unlock(); return f.tx }
func (f *fakeDB) Param(k string) string {
	if k == "server_version" {
		return "16.4 (Ubuntu)"
	}
	return ""
}
func (f *fakeDB) Cancel(context.Context) error {
	f.log("cancel")
	f.cancel <- struct{}{}
	return nil
}
func (f *fakeDB) Kill() {
	f.log("kill")
	select {
	case <-f.killed:
	default:
		close(f.killed)
	}
}
func (f *fakeDB) Close() error { f.log("close"); return nil }
func (f *fakeDB) PID() uint32  { return 4242 }

func sp(s string) *string { return &s }

const port = 47123

func newStudio(t *testing.T, f *fakeDB) (*Studio, *bytes.Buffer) {
	t.Helper()
	logb := &bytes.Buffer{}
	s, err := New(context.Background(), Config{App: "shop", Host: "prod", Admin: "admin", Role: "tando_shop",
		Database: "tando_shop", Password: "fake-pw-canary-1", Port: port, Idle: time.Hour, Heartbeat: 10 * time.Second,
		StmtLimit: 30 * time.Second, Out: io.Discard, Log: logb, Dial: func(context.Context) (DB, error) { return f, nil }})
	if err != nil {
		t.Fatal(err)
	}
	return s, logb
}

type call struct {
	method, path, body string
	hdr                map[string]string
	noAuth             bool
}

func do(s *Studio, c call) *httptest.ResponseRecorder {
	if c.method == "" {
		c.method = "GET"
		if c.body != "" {
			c.method = "POST"
		}
	}
	r := httptest.NewRequest(c.method, c.path, strings.NewReader(c.body))
	r.Host = fmt.Sprintf("127.0.0.1:%d", port)
	if c.body != "" {
		r.Header.Set("Content-Type", "application/json")
	}
	if !c.noAuth {
		r.Header.Set("Authorization", "Bearer "+s.token)
	}
	for k, v := range c.hdr {
		if k == "Host" {
			r.Host = v
		} else {
			r.Header.Set(k, v)
		}
	}
	w := httptest.NewRecorder()
	s.ServeHTTP(w, r)
	return w
}

type qresp struct {
	ID      string
	Results []struct {
		Stmt      int
		Offset    int
		Command   string
		Columns   []struct{ Name string }
		Rows      [][]*string
		Truncated bool
		Reason    string
	}
	Notices []struct{ Message string }
	Error   *struct {
		Stmt     int
		SQLState string
		Message  string
		Position int
	}
}

func query(t *testing.T, s *Studio, sql string) (qresp, *httptest.ResponseRecorder) {
	t.Helper()
	b, _ := json.Marshal(map[string]any{"id": "q1", "sql": sql, "max_rows": 3})
	w := do(s, call{path: "/api/query", body: string(b)})
	var q qresp
	if w.Code == 200 {
		if err := json.Unmarshal(w.Body.Bytes(), &q); err != nil {
			t.Fatalf("not JSON: %v\n%s", err, w.Body)
		}
	}
	return q, w
}

// ---- the read-only boundary --------------------------------------------------------------

// Every batch: the snapshot first (one simple query of the studio's own), one Exec per
// statement, then ROLLBACK and DISCARD ALL. Never a second BEGIN.
func TestReadOnlyWrapping(t *testing.T) {
	f := newFake(nil)
	s, _ := newStudio(t, f)
	q, w := query(t, s, "select 1;\n  select 2 ; ")
	if w.Code != 200 || q.Error != nil || len(q.Results) != 2 || q.Results[1].Offset != 12 {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
	want := []string{"simple BEGIN READ ONLY; SELECT 1", "exec select 1", "exec select 2", "simple ROLLBACK", "simple DISCARD ALL"}
	if got := f.Calls(); strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("calls\n got %q\nwant %q", got, want)
	}
}

// A statement that ended the studio's transaction (it cannot pass the allowlist; simulated
// here) stops the batch: no BEGIN is issued again, nothing after it runs.
func TestTransactionEndStopsTheBatch(t *testing.T) {
	f := newFake(func(sql string) step {
		if sql == "select 1" {
			return step{res: pgwire.Result{Tag: "COMMIT"}, tx: 'I'}
		}
		return step{res: pgwire.Result{Tag: "DELETE 1"}}
	})
	s, _ := newStudio(t, f)
	q, _ := query(t, s, "select 1; select 2")
	if q.Error == nil || q.Error.SQLState != "25000" || !strings.Contains(q.Error.Message, "transaction control") {
		t.Fatalf("%+v", q.Error)
	}
	for _, c := range f.Calls() {
		if c == "exec select 2" || strings.Count(strings.Join(f.Calls(), "|"), "BEGIN") != 1 {
			t.Fatalf("ran on after the transaction ended: %q", f.Calls())
		}
	}
}

// The bypasses of the review and more: refused before anything runs (not even BEGIN).
func TestRefusedStatementsRunNothing(t *testing.T) {
	for _, sql := range []string{
		"SET TRANSACTION READ WRITE; DELETE FROM t",
		"select 1; COMMIT; SET TRANSACTION READ WRITE; DELETE FROM t",
		"SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE; COMMIT; DELETE FROM t",
		"select 1; set local transaction_read_only = off; delete from t",
		"BEGIN READ WRITE; INSERT INTO t VALUES (1)",
		"ROLLBACK; INSERT INTO t VALUES (1)",
		"END; DELETE FROM t", "ABORT", "START TRANSACTION READ WRITE", "PREPARE TRANSACTION 'x'",
		"LOCK t IN ACCESS EXCLUSIVE MODE", "REINDEX TABLE t", "ANALYZE t", "VACUUM t", "NOTIFY c, 'x'",
		"COPY t TO STDOUT", "DO $$ BEGIN DELETE FROM t; COMMIT; END $$", "CALL p()", "SET ROLE postgres",
		"SET SESSION AUTHORIZATION postgres", `SET "role" = postgres`, "DISCARD ALL", "LISTEN x",
		"/* hidden */ delete from t", "(delete from t)",
	} {
		f := newFake(nil)
		s, _ := newStudio(t, f)
		q, w := query(t, s, sql)
		if w.Code != 200 || q.Error == nil || q.Error.SQLState != "25006" || len(f.Calls()) != 0 {
			t.Errorf("%q: %d %+v calls %q", sql, w.Code, q.Error, f.Calls())
		}
	}
	// the position of the refused statement, in characters
	f := newFake(nil)
	s, _ := newStudio(t, f)
	q, _ := query(t, s, "select 'é';\ncommit")
	if q.Error == nil || q.Error.Stmt != 1 || q.Error.Position != 13 {
		t.Fatalf("%+v", q.Error)
	}
}

func TestErrorPositionIsAbsolute(t *testing.T) {
	f := newFake(func(sql string) step {
		if strings.HasPrefix(sql, "select nope") {
			return step{res: pgwire.Result{Err: &pgwire.Error{Code: "42703", Message: `column "nope" does not exist`, Position: 8}}}
		}
		return step{cols: []string{"a"}, rows: [][]*string{{sp("1")}}, res: pgwire.Result{Tag: "SELECT 1"}}
	})
	s, _ := newStudio(t, f)
	q, _ := query(t, s, "select 1; select nope; select 3")
	if q.Error == nil || q.Error.Stmt != 1 || q.Error.Position != 10+8 || len(q.Results) != 1 {
		t.Fatalf("%+v %+v", q.Error, q.Results)
	}
	if c := f.Calls(); c[len(c)-2] != "simple ROLLBACK" || strings.Contains(strings.Join(c, "|"), "select 3") {
		t.Fatalf("%q", c)
	}
}

func TestRowLimitAndByteCap(t *testing.T) {
	rows := [][]*string{{sp("1")}, {sp("2")}, {sp("3")}, {sp("4")}}
	f := newFake(func(sql string) step {
		return step{cols: []string{"n"}, rows: rows, res: pgwire.Result{Tag: "SELECT 4", Suspended: true}}
	})
	s, _ := newStudio(t, f)
	q, _ := query(t, s, "select n")
	if len(q.Results) != 1 || len(q.Results[0].Rows) != 3 || !q.Results[0].Truncated || q.Results[0].Reason != "rows" {
		t.Fatalf("%+v", q.Results)
	}
	big := strings.Repeat("x", 3<<20)
	f = newFake(func(sql string) step {
		return step{cols: []string{"b"}, rows: [][]*string{{&big}, {&big}, {&big}}, res: pgwire.Result{Tag: "SELECT 3"}}
	})
	s, _ = newStudio(t, f)
	q, _ = query(t, s, "select b; select 2")
	if len(q.Results) != 1 || len(q.Results[0].Rows) != 2 || q.Results[0].Reason != "bytes" {
		t.Fatalf("byte cap: %d results, %+v", len(q.Results), q.Results[0].Reason)
	}
}

// The studio's own clock: a statement past the limit is cancelled, and one that does not stop
// has its connection closed; the next request gets a new connection.
func TestStatementClock(t *testing.T) {
	block := make(chan struct{})
	f := newFake(func(string) step { return step{block: block} })
	s, _ := newStudio(t, f)
	s.cfg.StmtLimit = 150 * time.Millisecond
	t0 := time.Now()
	q, _ := query(t, s, "select pg_sleep(40)")
	if q.Error == nil || q.Error.SQLState != "57014" || !strings.Contains(q.Error.Message, "limit") || time.Since(t0) > 2*time.Second {
		t.Fatalf("%+v after %v", q.Error, time.Since(t0))
	}
	f2 := newFake(func(string) step { return step{block: block, deaf: true} })
	s2, _ := newStudio(t, f2)
	s2.cfg.StmtLimit, s2.killAfter = 100*time.Millisecond, 100*time.Millisecond
	q, _ = query(t, s2, "select pg_sleep(40)")
	c := strings.Join(f2.Calls(), "|")
	if q.Error == nil || q.Error.SQLState != "08006" || !strings.Contains(c, "cancel|kill") || strings.Contains(c, "ROLLBACK") || s2.c.db != nil {
		t.Fatalf("%+v %s", q.Error, c)
	}
}

func TestCancelAndBusy(t *testing.T) {
	block := make(chan struct{})
	f := newFake(func(string) step { return step{block: block} })
	s, _ := newStudio(t, f)
	done := make(chan qresp)
	go func() { q, _ := query(t, s, "select pg_sleep(20)"); done <- q }()
	for !strings.Contains(strings.Join(f.Calls(), "|"), "exec") {
		time.Sleep(5 * time.Millisecond)
	}
	if w := do(s, call{path: "/api/tables"}); w.Code != 409 {
		t.Fatalf("a second request while one runs: %d", w.Code)
	}
	if w := do(s, call{path: "/api/cancel", body: `{"id":"q1"}`}); !strings.Contains(w.Body.String(), "true") {
		t.Fatalf("cancel: %s", w.Body)
	}
	q := <-done
	if q.Error == nil || q.Error.Message != "stopped (cancelled)" {
		t.Fatalf("%+v", q.Error)
	}
	if w := do(s, call{path: "/api/cancel", body: `{"id":"q1"}`}); !strings.Contains(w.Body.String(), "false") {
		t.Fatalf("cancel of nothing: %s", w.Body)
	}
}

// ---- the HTTP edge ------------------------------------------------------------------------

func TestRefusals(t *testing.T) {
	s, _ := newStudio(t, newFake(nil))
	cases := []struct {
		name string
		c    call
		code int
	}{
		{"no token", call{path: "/api/info", noAuth: true}, 401},
		{"wrong token", call{path: "/api/info", hdr: map[string]string{"Authorization": "Bearer x"}}, 401},
		{"token as a cookie", call{path: "/api/info", noAuth: true, hdr: map[string]string{"Cookie": "t=" + s.token}}, 401},
		{"foreign host", call{path: "/api/info", hdr: map[string]string{"Host": "evil.example:47123"}}, 403},
		{"host of another port", call{path: "/api/info", hdr: map[string]string{"Host": "127.0.0.1:47124"}}, 403},
		{"host with a trailing dot", call{path: "/api/info", hdr: map[string]string{"Host": "localhost.:47123"}}, 403},
		{"host without a port", call{path: "/api/info", hdr: map[string]string{"Host": "127.0.0.1"}}, 403},
		{"foreign host on the page", call{path: "/", noAuth: true, hdr: map[string]string{"Host": "evil.example"}}, 403},
		{"foreign origin", call{path: "/api/info", hdr: map[string]string{"Origin": "http://evil.example"}}, 403},
		{"origin of another port", call{path: "/api/info", hdr: map[string]string{"Origin": "http://127.0.0.1:1"}}, 403},
		{"cross-site fetch", call{path: "/api/info", hdr: map[string]string{"Sec-Fetch-Site": "cross-site"}}, 403},
		{"same-site fetch", call{path: "/api/info", hdr: map[string]string{"Sec-Fetch-Site": "same-site"}}, 403},
		{"form post", call{path: "/api/query", body: "x", hdr: map[string]string{"Content-Type": "application/x-www-form-urlencoded"}}, 415},
		{"text post", call{path: "/api/end", body: "{}", hdr: map[string]string{"Content-Type": "text/plain"}}, 415},
		{"preflight", call{method: "OPTIONS", path: "/api/query"}, 405},
		{"put", call{method: "PUT", path: "/api/query"}, 405},
		{"unknown endpoint", call{path: "/api/nope"}, 404},
		{"unknown field", call{path: "/api/query", body: `{"id":"a","sql":"select 1","write":true}`}, 400},
		{"bad id", call{path: "/api/query", body: `{"id":"a b","sql":"select 1"}`}, 400},
		{"too many rows", call{path: "/api/query", body: `{"id":"a","sql":"select 1","max_rows":10001}`}, 400},
		{"body too large", call{path: "/api/query", body: `{"id":"a","sql":"` + strings.Repeat("x", MaxBody) + `"}`}, 413},
		{"sql too large", call{path: "/api/query", body: `{"id":"a","sql":"` + strings.Repeat("x", MaxSQL+1) + `"}`}, 413},
		{"too many statements", call{path: "/api/query", body: `{"id":"a","sql":"` + strings.Repeat("select 1;", 101) + `"}`}, 400},
		{"rows: unknown table", call{path: "/api/rows", body: `{"schema":"public","name":"nope","limit":10}`}, 404},
	}
	for _, tc := range cases {
		w := do(s, tc.c)
		if w.Code != tc.code {
			t.Errorf("%s: %d, want %d (%s)", tc.name, w.Code, tc.code, w.Body)
		}
		if w.Header().Get("Content-Security-Policy") != csp || w.Header().Get("X-Content-Type-Options") != "nosniff" {
			t.Errorf("%s: security headers missing", tc.name)
		}
	}
}

func TestSecurityHeadersEveryRoute(t *testing.T) {
	s, _ := newStudio(t, newFake(nil))
	for _, p := range []string{"/", "/s.css", "/s.js", "/healthz", "/nope", "/api/info", "/api/ping", "/api/tables"} {
		w := do(s, call{path: p})
		h := w.Header()
		if h.Get("Content-Security-Policy") != csp || h.Get("Referrer-Policy") != "no-referrer" || h.Get("Cache-Control") != "no-store" ||
			h.Get("Cross-Origin-Opener-Policy") != "same-origin" || h.Get("Cross-Origin-Resource-Policy") != "same-origin" || h.Get("X-Frame-Options") != "DENY" {
			t.Errorf("%s: %v", p, h)
		}
	}
	if !strings.Contains(csp, "object-src 'none'") || !strings.Contains(csp, "require-trusted-types-for 'script'") || strings.Contains(csp, "unsafe") || strings.Contains(csp, "data:") {
		t.Fatal(csp)
	}
	w := do(s, call{path: "/healthz", noAuth: true})
	if w.Body.String() != "tando-studio "+s.probe+"\n" {
		t.Fatalf("healthz %q", w.Body)
	}
	w = do(s, call{path: "/s.js", noAuth: true, hdr: map[string]string{"Accept-Encoding": "gzip"}})
	if w.Header().Get("Content-Encoding") != "gzip" || w.Body.Len() >= len(s.static["/s.js"].raw) {
		t.Fatal("gzip")
	}
}

// The URL's code works once and for a minute; the token never comes from anywhere else.
func TestBootstrapCode(t *testing.T) {
	s, _ := newStudio(t, newFake(nil))
	now := time.Now()
	s.cfg.Now = func() time.Time { return now }
	body := `{"code":"` + s.code + `"}`
	w := do(s, call{path: "/api/session", body: body, noAuth: true})
	if w.Code != 200 || !strings.Contains(w.Body.String(), s.token) {
		t.Fatalf("first use: %d %s", w.Code, w.Body)
	}
	if w := do(s, call{path: "/api/session", body: body, noAuth: true}); w.Code != 401 || strings.Contains(w.Body.String(), s.token) {
		t.Fatalf("second use: %d", w.Code)
	}
	s2, _ := newStudio(t, newFake(nil))
	s2.cfg.Now = func() time.Time { return now.Add(CodeTTL + time.Second) }
	if w := do(s2, call{path: "/api/session", body: `{"code":"` + s2.code + `"}`, noAuth: true}); w.Code != 401 {
		t.Fatalf("expired: %d", w.Code)
	}
	if w := do(s2, call{path: "/api/session", body: `{"code":"nope"}`, noAuth: true}); w.Code != 401 {
		t.Fatalf("wrong code: %d", w.Code)
	}
	if strings.Contains(s.Ready(), s.token) || !strings.Contains(s.Ready(), s.code) {
		t.Fatal("the ready line carries the code, never the token")
	}
}

func TestInfoAndHistoryKey(t *testing.T) {
	s, _ := newStudio(t, newFake(nil))
	w := do(s, call{path: "/api/info"})
	var i struct {
		App, Role, Mode, PG_Version, Hkey string
		Limits                            struct{ Timeout_ms int }
	}
	json.Unmarshal(w.Body.Bytes(), &i)
	if i.App != "shop" || i.Role != "tando_shop" || i.Mode != "ro" || i.PG_Version != "16.4" || i.Limits.Timeout_ms != 30000 {
		t.Fatalf("%s", w.Body)
	}
	// HMAC-SHA256("fake-pw-canary-1", "tando studio history shop"), base64url (openssl dgst -sha256 -hmac)
	if i.Hkey != HistoryKey("fake-pw-canary-1", "shop") || HistoryKey("fake-pw-canary-1", "shop") != "lVGbAJFds6JdHxmfkpJbiOT7-cJcBT3BHBenBYxaG4s" {
		t.Fatalf("history key %q", HistoryKey("fake-pw-canary-1", "shop"))
	}
	if HistoryKey("fake-pw-canary-1", "other") == i.Hkey || strings.Contains(w.Body.String(), "fake-pw-canary-1") {
		t.Fatal("the key is per app and the password is not in the answer")
	}
}

// ---- the session's life ------------------------------------------------------------------

func TestLifeReasons(t *testing.T) {
	t0 := time.Unix(1e9, 0)
	l := life{beat: t0, active: t0, idle: 30 * time.Minute, hb: 45 * time.Second}
	if r := l.reason(t0.Add(44 * time.Second)); r != "" {
		t.Fatal(r)
	}
	if r := l.reason(t0.Add(46 * time.Second)); r != "heartbeat" {
		t.Fatal(r)
	}
	l.heartbeat(t0.Add(40 * time.Second))
	if r := l.reason(t0.Add(80 * time.Second)); r != "" {
		t.Fatal(r)
	}
	for m := 1; m <= 31; m++ { // heartbeats go on, no request
		l.heartbeat(t0.Add(time.Duration(m) * time.Minute))
	}
	if r := l.reason(t0.Add(31 * time.Minute)); r != "idle" {
		t.Fatal(r)
	}
	l.touch(t0.Add(31 * time.Minute))
	if r := l.reason(t0.Add(31 * time.Minute)); r != "" {
		t.Fatal(r)
	}
	l.closed()
	if r := l.reason(t0.Add(31 * time.Minute)); r != "eof" {
		t.Fatal(r)
	}
}

func TestServeEndsOnEOFAndEnd(t *testing.T) {
	for _, how := range []string{"eof", "end", "idle", "heartbeat"} {
		f := newFake(nil)
		s, _ := newStudio(t, f)
		var out bytes.Buffer
		s.cfg.Out = &out
		dir, _ := os.MkdirTemp("/tmp", "st")
		defer os.RemoveAll(dir)
		ln, err := Listen(dir + "/s")
		if err != nil {
			t.Fatal(err)
		}
		in, inw := io.Pipe()
		now := time.Now()
		var mu sync.Mutex
		s.cfg.Now = func() time.Time { mu.Lock(); defer mu.Unlock(); return now }
		res := make(chan string)
		go func() { res <- s.Serve(ln, in, 10*time.Millisecond) }()
		switch how {
		case "eof":
			inw.Close()
		case "end":
			do(s, call{path: "/api/end", body: "{}"})
		case "idle", "heartbeat":
			if how == "idle" {
				go func() {
					for {
						if _, err := inw.Write([]byte{'\n'}); err != nil {
							return
						}
						time.Sleep(5 * time.Millisecond)
					}
				}()
				s.life.idle = time.Minute
			}
			mu.Lock()
			now = now.Add(2 * time.Minute)
			mu.Unlock()
		}
		select {
		case r := <-res:
			if r != how || !strings.Contains(out.String(), "stopped reason="+how+" queries=0") || !strings.HasPrefix(out.String(), "ready code=") {
				t.Fatalf("%s: %q %q", how, r, out.String())
			}
			if c := f.Calls(); len(c) == 0 || c[len(c)-1] != "close" {
				t.Fatalf("%s: the connection was not closed: %q", how, c)
			}
		case <-time.After(3 * time.Second):
			t.Fatalf("%s: still serving", how)
		}
		inw.Close()
	}
}

// Nothing of a query (its text, its values) reaches the journal.
func TestLogHasNoSQLNorValues(t *testing.T) {
	f := newFake(func(string) step {
		return step{cols: []string{"secret"}, rows: [][]*string{{sp("cell-canary-77")}}, res: pgwire.Result{Tag: "SELECT 1"}}
	})
	s, logb := newStudio(t, f)
	query(t, s, "select 'sql-canary-55' as secret")
	query(t, s, "commit -- sql-canary-56")
	do(s, call{path: "/api/rows", body: `{"schema":"x","name":"sql-canary-57","limit":5}`})
	if l := logb.String(); strings.Contains(l, "canary") {
		t.Fatalf("the log has query data: %q", l)
	}
}

// The connection is refused when the app (or the server) would have fewer than 2 left.
func TestConnectionSlots(t *testing.T) {
	for _, tc := range []struct {
		row  []string
		want string
	}{
		{[]string{"9", "10", "9", "17"}, "uses 8 of its 10"},
		{[]string{"8", "10", "8", "17"}, ""},
		{[]string{"1", "10", "16", "17"}, "15 of its 17"},
		{[]string{"5", "-1", "5", "17"}, ""},
	} {
		f := newFake(nil)
		f.slots = tc.row
		_, err := New(context.Background(), Config{App: "shop", Host: "h", Admin: "a", Password: "fake-pw", Port: port,
			Idle: time.Hour, Out: io.Discard, Log: io.Discard, Dial: func(context.Context) (DB, error) { return f, nil }})
		if tc.want == "" && err != nil || tc.want != "" && (err == nil || !strings.Contains(err.Error(), tc.want)) {
			t.Errorf("%v: %v", tc.row, err)
		}
	}
}

// The backend's pid goes to stdout (the agent lowers its priority); the settings are there.
func TestBackendLineAndSettings(t *testing.T) {
	f := newFake(nil)
	var out bytes.Buffer
	_, err := New(context.Background(), Config{App: "shop", Host: "h", Admin: "a", Password: "fake-pw", Port: port,
		Idle: time.Hour, Out: &out, Log: io.Discard, Dial: func(context.Context) (DB, error) { return f, nil }})
	if err != nil || out.String() != "backend pid=4242\n" {
		t.Fatalf("%v %q", err, out.String())
	}
	p := map[string]string{}
	for _, kv := range startupParams(Config{StmtLimit: 30 * time.Second}) {
		p[kv[0]] = kv[1]
	}
	for k, v := range map[string]string{"work_mem": "2MB", "hash_mem_multiplier": "1", "max_parallel_workers_per_gather": "0",
		"max_parallel_workers": "0", "temp_buffers": "1MB", "jit": "off", "lock_timeout": "2s", "statement_timeout": "32000ms",
		"default_transaction_read_only": "on", "idle_in_transaction_session_timeout": "60s"} {
		if p[k] != v {
			t.Errorf("%s = %q, want %q", k, p[k], v)
		}
	}
}

// Unused for ConnIdle: the database connection is closed; the next request opens one.
func TestIdleConnectionClosed(t *testing.T) {
	f := newFake(nil)
	s, _ := newStudio(t, f)
	now := time.Now()
	s.c.used = now
	s.c.idleClose(now.Add(30*time.Second), time.Minute)
	if s.c.db == nil {
		t.Fatal("closed too early")
	}
	s.c.idleClose(now.Add(61*time.Second), time.Minute)
	if s.c.db != nil || f.Calls()[len(f.Calls())-1] != "close" {
		t.Fatalf("not closed: %q", f.Calls())
	}
	if q, _ := query(t, s, "select 1"); q.Error != nil || s.c.db == nil {
		t.Fatalf("no new connection: %+v", q.Error)
	}
}

// The last statement of a batch ended the transaction: still reported.
func TestTransactionEndOnLastStatement(t *testing.T) {
	f := newFake(func(string) step { return step{res: pgwire.Result{Tag: "COMMIT"}, tx: 'I'} })
	s, _ := newStudio(t, f)
	q, _ := query(t, s, "select 1")
	if q.Error == nil || q.Error.SQLState != "25000" {
		t.Fatalf("%+v", q.Error)
	}
}
