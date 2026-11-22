package ctl

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"tando/srv/internal/env"
	"tando/srv/internal/lock"
	"tando/srv/internal/run"
)

func TestParse(t *testing.T) {
	ok := []string{
		`{"v":1,"verb":"inventory"}`,
		`{"v":1,"verb":"app.restart","app":"shop","request_id":"0b8f4c1e-2d3a-4b5c-8d9e-0f1a2b3c4d5e"}`,
		`{"v":1,"verb":"usage","args":{"since":5}}`,
		` {"v":1,"verb":"alerts","app":"shop"}` + "\n",
	}
	for _, s := range ok {
		if _, e := Parse([]byte(s)); e != nil {
			t.Errorf("%s: %+v", s, e)
		}
	}
	bad := map[string]string{
		`{"v":2,"verb":"inventory"}`:                           "unsupported_version",
		`{"verb":"inventory"}`:                                 "unsupported_version",
		`{"v":1,"verb":"shell"}`:                               "unknown_verb",
		`{"v":1,"verb":"inventory","extra":1}`:                 "bad_request",
		`{"v":1,"verb":"inventory"}{"v":1,"verb":"inventory"}`: "bad_request",
		`[1]`:                         "bad_request",
		`{"v":1,"verb":"app.status"}`: "bad_request",
		`{"v":1,"verb":"inventory","app":"shop"}`:                                  "bad_request",
		`{"v":1,"verb":"app.status","app":"../etc"}`:                               "bad_request",
		`{"v":1,"verb":"app.restart","app":"shop"}`:                                "bad_request", // no request_id
		`{"v":1,"verb":"app.restart","app":"shop","request_id":"short"}`:           "bad_request",
		`{"v":1,"verb":"app.restart","app":"shop","request_id":"a b c d e f g h"}`: "bad_request",
	}
	for s, code := range bad {
		if _, e := Parse([]byte(s)); e == nil || e.Code != code {
			t.Errorf("%s: %+v, want %s", s, e, code)
		}
	}
	big := `{"v":1,"verb":"inventory","args":"` + strings.Repeat("x", MaxRequest) + `"}`
	if _, e := Parse([]byte(big)); e == nil {
		t.Error("oversized request accepted")
	}
}

func TestAllowed(t *testing.T) {
	read, write := Ident{Mode: ModeRead}, Ident{Mode: ModeWrite}
	app := Ident{Mode: ModeApp, App: "shop"}
	cases := []struct {
		id      Ident
		verb    string
		app     string
		allowed bool
	}{
		{read, "inventory", "", true},
		{read, "app.status", "x", true},
		{read, "app.restart", "x", false},
		{read, "app.destroy", "x", false},
		{write, "app.destroy", "x", true},
		{write, "app.env.set", "x", true},
		{app, "app.restart", "shop", true},
		{app, "app.env.set", "shop", true},
		{app, "app.restart", "other", false},
		{app, "app.status", "other", false},
		{app, "app.destroy", "shop", false},
		{app, "inventory", "", false},
		{app, "usage", "other", false},
		{Ident{Mode: "admin"}, "inventory", "", false},
	}
	for _, c := range cases {
		r := Request{Verb: c.verb, App: c.app}
		if e := Allowed(c.id, &r); (e == nil) != c.allowed {
			t.Errorf("%+v %s %s: %+v", c.id, c.verb, c.app, e)
		}
	}
	// an app's principal reading alerts or usage sees its own app
	r := Request{Verb: "usage"}
	if e := Allowed(app, &r); e != nil || r.App != "shop" {
		t.Errorf("usage narrowed: %+v %+v", r, e)
	}
}

func newStore(t *testing.T) *Store {
	return &Store{Dir: filepath.Join(t.TempDir(), "ctl"), NS: "write", Poll: 5 * time.Millisecond}
}

func req(id, verb, app string, args string) Request {
	r := Request{V: 1, Verb: verb, App: app, RequestID: id}
	if args != "" {
		r.Args = json.RawMessage(args)
	}
	return r
}

// Many sessions with one request id at once (a client retrying over flaky links): the work runs
// once; every session gets its response, the later ones marked replayed.
func TestStoreSameIDConcurrent(t *testing.T) {
	s := newStore(t)
	var runs atomic.Int32
	r := req("req-00000001", "app.restart", "shop", "")
	var wg sync.WaitGroup
	resps := make([]Response, 8)
	for i := range resps {
		wg.Add(1)
		go func() {
			defer wg.Done()
			resps[i] = s.Do(r, time.Minute, func() Response {
				runs.Add(1)
				time.Sleep(200 * time.Millisecond)
				return Response{V: 1, OK: true, Verb: r.Verb, App: r.App, Result: map[string]string{"healthy": "1"}}
			})
		}()
	}
	wg.Wait()
	if runs.Load() != 1 {
		t.Fatalf("ran %d times", runs.Load())
	}
	replayed := 0
	for _, x := range resps {
		if !x.OK || x.RequestID != r.RequestID {
			t.Errorf("response %+v", x)
		}
		if x.Replayed {
			replayed++
		}
	}
	if replayed != len(resps)-1 {
		t.Errorf("%d replayed, want %d", replayed, len(resps)-1)
	}
	// later: the stored result, nothing runs; another request under the same id is refused
	x := s.Do(r, time.Minute, func() Response { runs.Add(1); return Response{} })
	if !x.Replayed || !x.OK || runs.Load() != 1 {
		t.Errorf("finished id: %+v", x)
	}
	x = s.Do(req("req-00000001", "app.stop", "shop", ""), time.Minute, func() Response { runs.Add(1); return Response{} })
	if x.Error == nil || x.Error.Code != "conflict" || runs.Load() != 1 {
		t.Errorf("reused id: %+v", x)
	}
	// the same arguments in another order are the same request
	a := req("req-00000002", "app.env.set", "shop", `{"vars":{"A":"1","B":"2"}}`)
	b := req("req-00000002", "app.env.set", "shop", `{"vars":{"B":"2","A":"1"}}`)
	k := []byte("0123456789abcdef0123456789abcdef")
	if Digest(k, "write", a) != Digest(k, "write", b) {
		t.Error("digest depends on key order")
	}
	// the stored record holds no argument values (env values are secrets)
	s.Do(a, time.Minute, func() Response { return Response{OK: true} })
	data, _ := os.ReadFile(filepath.Join(s.Dir, "req", "write", "req-00000002.json"))
	if bytes.Contains(data, []byte(`"1"`)) || bytes.Contains(data, []byte("vars")) {
		t.Errorf("record holds arguments: %s", data)
	}
}

// A retry that finds the first attempt still running, but cannot wait as long, is told it is
// pending; a record left pending by a crash (nobody holds its lock) is interrupted, once and for all.
func TestStorePendingAndInterrupted(t *testing.T) {
	s := newStore(t)
	r := req("req-slow-0001", "app.restart", "shop", "")
	started, release := make(chan struct{}), make(chan struct{})
	done := make(chan Response)
	go func() {
		done <- s.Do(r, time.Minute, func() Response { close(started); <-release; return Response{OK: true} })
	}()
	<-started
	if x := s.Do(r, 50*time.Millisecond, func() Response { t.Error("ran twice"); return Response{} }); x.Error == nil || x.Error.Code != "pending" {
		t.Errorf("while running: %+v", x)
	}
	close(release)
	if x := <-done; !x.OK || x.Replayed {
		t.Errorf("first: %+v", x)
	}

	// a crash: the record says pending, nobody runs it
	c := req("req-crash-001", "app.stop", "shop", "")
	s.init()
	key, _ := s.key()
	rec := record{ID: c.RequestID, Digest: Digest(key, "write", c), Verb: c.Verb, App: c.App, Seq: 99, State: "pending"}
	if err := s.save(rec); err != nil {
		t.Fatal(err)
	}
	os.MkdirAll(filepath.Join(s.Dir, "queue", "shop"), 0o700)
	os.WriteFile(filepath.Join(s.Dir, "queue", "shop", "0000000000000099-write+req-crash-001"), nil, 0o600)
	x := s.Do(c, time.Minute, func() Response { t.Error("ran a cut-off request again"); return Response{} })
	if x.Error == nil || x.Error.Code != "interrupted" || !x.Replayed {
		t.Errorf("cut off: %+v", x)
	}
	x = s.Do(c, time.Minute, func() Response { t.Error("ran"); return Response{} })
	if x.Error == nil || x.Error.Code != "interrupted" {
		t.Errorf("cut off, again: %+v", x)
	}
	// its queue entry no longer holds the app up
	y := s.Do(req("req-after-001", "app.start", "shop", ""), time.Minute, func() Response { return Response{OK: true} })
	if !y.OK {
		t.Errorf("after: %+v", y)
	}
}

// Requests of one app run one at a time, in arrival order; another app's do not wait.
func TestStoreOrderPerApp(t *testing.T) {
	s := newStore(t)
	var mu sync.Mutex
	var order []string
	running := map[string]int{}
	gate := make(chan struct{})
	do := func(id, app string, hold bool) Response {
		return s.Do(req(id, "app.restart", app, ""), time.Minute, func() Response {
			mu.Lock()
			running[app]++
			if running[app] > 1 {
				t.Errorf("two requests of %s at once", app)
			}
			order = append(order, id)
			mu.Unlock()
			if hold {
				<-gate
			}
			time.Sleep(20 * time.Millisecond)
			mu.Lock()
			running[app]--
			mu.Unlock()
			return Response{OK: true}
		})
	}
	var wg sync.WaitGroup
	wg.Add(1)
	go func() { defer wg.Done(); do("shop-first-1", "shop", true) }()
	for !lock.Held(filepath.Join(s.Dir, "req", "write", "shop-first-1.lock")) {
		time.Sleep(time.Millisecond)
	}
	wg.Add(1)
	go func() { defer wg.Done(); do("shop-second-1", "shop", false) }()
	for {
		ents, _ := os.ReadDir(filepath.Join(s.Dir, "queue", "shop"))
		if len(ents) == 2 {
			break
		}
		time.Sleep(time.Millisecond)
	}
	// blog is not held up by shop
	if x := do("blog-only-001", "blog", false); !x.OK {
		t.Error(x)
	}
	mu.Lock()
	if strings.Join(order, ",") != "shop-first-1,blog-only-001" {
		t.Errorf("order while shop's first runs: %v", order)
	}
	mu.Unlock()
	close(gate)
	wg.Wait()
	if strings.Join(order, ",") != "shop-first-1,blog-only-001,shop-second-1" {
		t.Errorf("order %v", order)
	}
}

func TestStorePrune(t *testing.T) {
	s := newStore(t)
	now := time.Unix(1_800_000_000, 0)
	s.Now = func() time.Time { return now }
	s.Do(req("old-request-1", "app.restart", "shop", ""), time.Minute, func() Response { return Response{OK: true} })
	now = now.Add(Retention + pruneEvery + time.Hour)
	s.Do(req("new-request-1", "app.restart", "shop", ""), time.Minute, func() Response { return Response{OK: true} })
	if _, ok := s.load("old-request-1"); ok {
		t.Error("an old record was kept")
	}
	if _, ok := s.load("new-request-1"); !ok {
		t.Error("the new record is gone")
	}
}

// Serve end to end with a fake tando-agent: mutating verbs reach the agent with the checked
// arguments (env values on stdin, never in argv), and a retry does not reach it again.
func TestServe(t *testing.T) {
	dir := t.TempDir()
	var calls []string
	var stdins []string
	e := env.Env{Root: filepath.Join(dir, "opt"), Lib: filepath.Join(dir, "lib"), Proc: filepath.Join(dir, "proc"),
		Now: time.Now,
		Run: run.Func(func(_ context.Context, c run.Cmd) ([]byte, error) {
			calls = append(calls, strings.Join(c.Argv, " "))
			in := ""
			if c.Stdin != nil {
				b := new(bytes.Buffer)
				b.ReadFrom(c.Stdin)
				in = b.String()
			}
			stdins = append(stdins, in)
			switch {
			case c.Argv[0] == "systemctl":
				return []byte("ActiveState=active\n"), nil
			case strings.HasSuffix(c.Argv[0], "tando-agent") && c.Argv[1] == "rollback":
				c.Stderr.Write([]byte("tando-agent: no earlier verified release to roll back to\n"))
				return nil, errors.New("exit status 1")
			}
			return []byte("healthy=1\nrestarted=1\nnot a kv\nBAD=1\n"), nil
		})}
	os.MkdirAll(filepath.Join(e.Root, "apps", "shop"), 0o755)
	os.WriteFile(filepath.Join(e.Root, "apps", "shop", "app.conf"), []byte("memory=512M\nidle_stop=5m\n"), 0o644)
	os.WriteFile(filepath.Join(e.Root, "apps", "shop", "state"), []byte("current=20261122-100000\n"), 0o644)
	os.MkdirAll(e.Proc, 0o755)
	os.WriteFile(filepath.Join(e.Proc, "meminfo"), []byte("MemTotal: 2048000 kB\nMemAvailable: 1024000 kB\n"), 0o644)
	c := New(e)
	var logs []string
	c.Log = func(m string) { logs = append(logs, m) }
	serve := func(id Ident, s string) (Response, int) {
		var b bytes.Buffer
		code := c.Serve(context.Background(), id, []byte(s), &b)
		var r Response
		if err := json.Unmarshal(b.Bytes(), &r); err != nil {
			t.Fatalf("not JSON: %q", b.String())
		}
		return r, code
	}
	w := Ident{Mode: ModeWrite, Serial: "7", KeyID: "cp"}
	r, code := serve(w, `{"v":1,"verb":"app.env.set","app":"shop","request_id":"env-0000001","args":{"vars":{"B":"two words","A":"1"}}}`)
	if !r.OK || code != 0 || calls[0] != agentPath+" env-set shop" || stdins[0] != "A=1\nB=two words\n" {
		t.Fatalf("env set: %+v %q %q", r, calls, stdins)
	}
	if m, _ := r.Result.(map[string]any); m["healthy"] != "1" || m["BAD"] != nil || len(m) != 2 {
		t.Errorf("result %+v", r.Result)
	}
	r, _ = serve(w, `{"v":1,"verb":"app.env.set","app":"shop","request_id":"env-0000001","args":{"vars":{"A":"1","B":"two words"}}}`)
	if !r.OK || !r.Replayed || len(calls) != 1 {
		t.Errorf("retry: %+v %q", r, calls)
	}
	r, code = serve(w, `{"v":1,"verb":"app.rollback","app":"shop","request_id":"rb-00000001"}`)
	if r.OK || code != 1 || r.Error.Code != "failed" || r.Error.Message != "no earlier verified release to roll back to" {
		t.Errorf("rollback: %+v", r)
	}
	r, _ = serve(w, `{"v":1,"verb":"app.destroy","app":"shop","request_id":"rm-00000001","args":{"confirm":"shp"}}`)
	if r.OK || r.Error.Code != "bad_request" {
		t.Errorf("destroy without confirm: %+v", r)
	}
	r, _ = serve(w, `{"v":1,"verb":"app.restart","app":"nope","request_id":"rs-00000001"}`)
	if r.OK || r.Error.Code != "not_found" {
		t.Errorf("no app: %+v", r)
	}
	r, _ = serve(w, `{"v":1,"verb":"app.env.set","app":"shop","request_id":"env-0000002","args":{"vars":{"A":"x\ny"}}}`)
	if r.OK || r.Error.Code != "bad_request" {
		t.Errorf("newline in a value: %+v", r)
	}
	n := len(calls)
	r, _ = serve(Ident{Mode: ModeRead}, `{"v":1,"verb":"app.restart","app":"shop","request_id":"rs-00000002"}`)
	if r.OK || r.Error.Code != "forbidden" || len(calls) != n {
		t.Errorf("read principal: %+v", r)
	}
	r, _ = serve(Ident{Mode: ModeRead}, `{"v":1,"verb":"inventory"}`)
	if !r.OK {
		t.Fatalf("inventory: %+v", r)
	}
	inv, _ := json.Marshal(r.Result)
	for _, want := range []string{`"mem_total_mb":2000`, `"alloc_mb":512`, `"admitted_mb":105`, `"admit_limit_mb":3000`, `"state":"active"`, `"current":"20261122-100000"`} {
		if !strings.Contains(string(inv), want) {
			t.Errorf("inventory lacks %s: %s", want, inv)
		}
	}
	if len(logs) == 0 || !strings.Contains(logs[0], "ctl write serial=7 key=cp verb=app.env.set app=shop request_id=env-0000001 result=ok") {
		t.Errorf("log %q", logs)
	}
}

// F2: request ids, quotas and eviction are per principal. An app's certificate filling its own
// namespace never pushes out the write principal's records (a retry of those must not run
// again), and it is refused (busy) once all its own records are recent.
func TestStorePerPrincipal(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "ctl")
	now := time.Unix(1_800_000_000, 0)
	clock := func() time.Time { return now }
	w := &Store{Dir: dir, NS: "write", Now: clock, Cap: 3}
	a := &Store{Dir: dir, NS: "app-shop", Now: clock, Cap: 3}
	var runs atomic.Int32
	ok := func() Response { runs.Add(1); return Response{OK: true} }
	rb := req("rollback-0001", "app.rollback", "shop", "")
	if x := w.Do(rb, time.Minute, ok); !x.OK || runs.Load() != 1 {
		t.Fatal(x)
	}
	// the same id under another principal is its own request (no squatting, no replay)
	if x := a.Do(rb, time.Minute, ok); !x.OK || x.Replayed || runs.Load() != 2 {
		t.Errorf("app principal, same id: %+v", x)
	}
	for i := 0; i < 2; i++ {
		if x := a.Do(req(fmt.Sprintf("flood-%07d", i), "app.restart", "shop", ""), time.Minute, ok); !x.OK {
			t.Fatalf("flood %d: %+v", i, x)
		}
	}
	x := a.Do(req("flood-0000099", "app.restart", "shop", ""), time.Minute, ok)
	if x.Error == nil || x.Error.Code != "busy" {
		t.Errorf("full namespace, all recent: %+v", x)
	}
	n := runs.Load()
	if x := w.Do(rb, time.Minute, ok); !x.Replayed || runs.Load() != n {
		t.Errorf("the write principal's retry ran again: %+v", x)
	}
	// a day later the app's own oldest records make room; the write record is still there
	now = now.Add(Recent + time.Hour)
	if x := a.Do(req("flood-0000100", "app.restart", "shop", ""), time.Minute, ok); !x.OK {
		t.Errorf("after a day: %+v", x)
	}
	if _, ok := w.load("rollback-0001"); !ok {
		t.Error("the write principal's record was evicted")
	}
}

// a request refused before it did anything is not kept: the same id with a fixed request runs
func TestStoreKeepsNoRefusal(t *testing.T) {
	s := newStore(t)
	r := req("fix-me-00001", "app.restart", "shop", "")
	if x := s.Do(r, time.Minute, func() Response { return fail(r, "bad_request", "args") }); x.Error == nil {
		t.Fatal(x)
	}
	if _, ok := s.load(r.RequestID); ok {
		t.Error("a refused request was kept")
	}
	if x := s.Do(r, time.Minute, func() Response { return Response{OK: true} }); !x.OK || x.Replayed {
		t.Errorf("second try: %+v", x)
	}
}

// the digest is keyed: the same request under another key (another node) does not match
func TestDigestKeyed(t *testing.T) {
	r := req("env-00000001", "app.env.set", "shop", `{"vars":{"PIN":"1234"}}`)
	if Digest([]byte("k1"), "write", r) == Digest([]byte("k2"), "write", r) ||
		Digest([]byte("k1"), "write", r) == Digest([]byte("k1"), "app-shop", r) {
		t.Error("digest ignores the key or the principal")
	}
}

// F3: what a request names reaches the journal as one quoted field, never as forged fields or lines
func TestServeLogNoInjection(t *testing.T) {
	c := New(env.Env{Root: t.TempDir(), Lib: t.TempDir(), Now: time.Now})
	var logs []string
	c.Log = func(m string) { logs = append(logs, m) }
	for _, in := range []string{
		`{"v":2,"verb":"inventory result=ok\nctl write verb=app.destroy result=ok","app":"x y"}`,
		`{"v":1,"verb":"inventory","app":"a result=ok"}`,
		`{"v":1,"verb":"app.restart","app":"shop","request_id":"x result=ok\n"}`,
	} {
		c.Serve(context.Background(), Ident{Mode: ModeRead, Serial: "1", KeyID: "k"}, []byte(in), new(bytes.Buffer))
	}
	quoted := regexp.MustCompile(`"(?:[^"\\]|\\.)*"`)
	if len(logs) != 3 {
		t.Fatalf("%d lines", len(logs))
	}
	for _, l := range logs {
		bare := quoted.ReplaceAllString(l, "Q")
		if strings.ContainsAny(l, "\n\r") || strings.Count(bare, " result=") != 1 || strings.Count(bare, " verb=") != 1 {
			t.Errorf("log line %q", l)
		}
	}
}
