package dash

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// blockRunner: counts runs; each run waits for release (or its context)
type blockRunner struct {
	n       atomic.Int32
	release chan struct{}
}

func (b *blockRunner) Run(ctx context.Context, q Req) (Result, error) {
	b.n.Add(1)
	if q.OnStart != nil {
		q.OnStart(4242)
	}
	if q.Out != nil {
		q.Out.WriteString("step 1\nstep 2\n")
	}
	select {
	case <-b.release:
	case <-ctx.Done():
		return Result{}, ctx.Err()
	}
	return Result{Stdout: []byte("tando 0.2.2\n")}, nil
}

func (e *env) confirmTok(action, host, app string) string {
	e.t.Helper()
	st, m := e.post("/api/confirm", map[string]string{"action": action, "host": host, "app": app})
	if st != 200 {
		e.t.Fatalf("confirm: %d %v", st, m)
	}
	return m["token"].(string)
}

func (e *env) act(key string, body map[string]string) (int, map[string]any) {
	var opts []reqOpt
	if key != "" {
		opts = append(opts, hdr("Idempotency-Key", key))
	}
	return e.post("/api/action", body, opts...)
}

func TestConfirmToken(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	var mu sync.Mutex
	clock := func() time.Time { mu.Lock(); defer mu.Unlock(); return now }
	br := &blockRunner{release: make(chan struct{})}
	close(br.release)
	e := newEnv(t, br, func(c *Config) { c.Now = clock })
	e.login()

	if st, _ := e.post("/api/confirm", map[string]string{"action": "format-disk", "host": "a", "app": "web"}); st != 400 {
		t.Fatal("unknown action got a token")
	}
	if st, _ := e.post("/api/confirm", map[string]string{"action": "noop", "host": "a", "app": "../x"}); st != 400 {
		t.Fatal("bad app got a token")
	}
	if st, _ := e.post("/api/confirm", map[string]string{"action": "noop", "host": "zz", "app": "web"}); st != 404 {
		t.Fatal("unknown host got a token")
	}
	// no token, a made-up one, one for another app, another host, another action
	body := func(tok string) map[string]string {
		return map[string]string{"action": "noop", "host": "a", "app": "web", "confirm": tok}
	}
	if st, m := e.act("key-none-0001", body("")); st != 403 || errCode(m) != "confirm" {
		t.Fatalf("no token: %d %v", st, m)
	}
	if st, _ := e.act("key-fake-0001", body("0123456789abcdef0123456789abcdef")); st != 403 {
		t.Fatal("made-up token")
	}
	other := e.confirmTok("noop", "a", "shop")
	if st, _ := e.act("key-other-001", body(other)); st != 403 {
		t.Fatal("token of another app")
	}
	otherHost := e.confirmTok("noop", "b", "web")
	if st, _ := e.act("key-other-002", body(otherHost)); st != 403 {
		t.Fatal("token of another host")
	}
	// expiry
	tok := e.confirmTok("noop", "a", "web")
	mu.Lock()
	now = now.Add(61 * time.Second)
	mu.Unlock()
	if st, _ := e.act("key-expired-1", body(tok)); st != 403 {
		t.Fatal("expired token")
	}
	// single use: a token used once does not admit a second write (other key)
	tok = e.confirmTok("noop", "a", "web")
	if st, m := e.act("key-good-0001", body(tok)); st != 202 {
		t.Fatalf("good: %d %v", st, m)
	}
	until(2*time.Second, func() bool { return e.srv.WritesRunning() == 0 })
	if st, _ := e.act("key-good-0002", body(tok)); st != 403 {
		t.Fatal("token used twice")
	}
	if br.n.Load() != 1 {
		t.Fatalf("runs %d", br.n.Load())
	}
	// a refused admission is not remembered: the same key works with a fresh token
	if st, _ := e.act("key-retry-001", body("")); st != 403 {
		t.Fatal("expected 403")
	}
	if st, _ := e.act("key-retry-001", body(e.confirmTok("noop", "a", "web"))); st != 202 {
		t.Fatal("key of a refused request not usable again")
	}
	// no Idempotency-Key, or a bad one
	if st, m := e.act("", body(e.confirmTok("noop", "a", "web"))); st != 400 || errCode(m) != "idempotency_key" {
		t.Fatal("no key")
	}
	if st, _ := e.act("bad key!", body(e.confirmTok("noop", "a", "web"))); st != 400 {
		t.Fatal("bad key")
	}
}

func TestIdempotency(t *testing.T) {
	br := &blockRunner{release: make(chan struct{})}
	e := newEnv(t, br, nil)
	e.login()
	body := map[string]string{"action": "noop", "host": "a", "app": "web", "confirm": e.confirmTok("noop", "a", "web")}
	st, m := e.act("idem-key-0001", body)
	if st != 202 || m["status"] != "running" || m["replay"] != false {
		t.Fatalf("%d %v", st, m)
	}
	// same key again (double click, retry, two tabs): the first request's record, no new run;
	// the confirm token it carries was already used, and that does not matter
	for i := 0; i < 3; i++ {
		st, m = e.act("idem-key-0001", body)
		if st != 202 || m["replay"] != true || m["status"] != "running" {
			t.Fatalf("replay: %d %v", st, m)
		}
	}
	// a fresh token in the retry does not change the body that counts
	body2 := map[string]string{"action": "noop", "host": "a", "app": "web", "confirm": e.confirmTok("noop", "a", "web")}
	if st, m = e.act("idem-key-0001", body2); st != 202 || m["replay"] != true {
		t.Fatalf("replay with fresh token: %d %v", st, m)
	}
	// same key, another body: 422
	if st, m = e.act("idem-key-0001", map[string]string{"action": "noop", "host": "a", "app": "shop"}); st != 422 || errCode(m) != "key_reused" {
		t.Fatalf("other body: %d %v", st, m)
	}
	close(br.release)
	if !until(3*time.Second, func() bool { _, m := e.get("/api/action?key=idem-key-0001"); return m["status"] == "done" }) {
		t.Fatal("not done")
	}
	st, m = e.act("idem-key-0001", body)
	if st != 200 || m["status"] != "done" || m["replay"] != true {
		t.Fatalf("after done: %d %v", st, m)
	}
	_, m = e.get("/api/action?key=idem-key-0001")
	if m["output"] != "step 1\nstep 2\n" {
		t.Fatalf("output: %v", m)
	}
	if br.n.Load() != 1 {
		t.Fatalf("%d runs", br.n.Load())
	}

	// persisted across a restart, file 0600
	p := filepath.Join(e.dir, "cache", "dash-idem.json")
	if fi, err := os.Stat(p); err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("idem file: %v %v", fi, err)
	}
	e2 := newEnvAt(t, e.dir, br)
	e2.login()
	st, m = e2.act("idem-key-0001", body)
	if st != 200 || m["status"] != "done" || m["replay"] != true {
		t.Fatalf("after restart: %d %v", st, m)
	}
	if st, _ = e2.act("idem-key-0001", map[string]string{"action": "noop", "host": "b", "app": "web"}); st != 422 {
		t.Fatal("other body after restart")
	}
	if br.n.Load() != 1 {
		t.Fatalf("%d runs after restart", br.n.Load())
	}
}

// newEnvAt: a second server on the same config dir (a restart)
func newEnvAt(t *testing.T, dir string, r Runner) *env {
	e := newEnv(t, r, func(c *Config) { c.ConfigDir = dir })
	e.dir = dir
	return e
}

func TestIdempotencyConcurrentSameKey(t *testing.T) {
	br := &blockRunner{release: make(chan struct{})}
	close(br.release)
	e := newEnv(t, br, nil)
	e.login()
	body := map[string]string{"action": "noop", "host": "a", "app": "web", "confirm": e.confirmTok("noop", "a", "web")}
	var wg sync.WaitGroup
	sts := make([]int, 30)
	for i := range sts {
		wg.Add(1)
		go func() { defer wg.Done(); sts[i], _ = e.act("conc-key-0001", body) }()
	}
	wg.Wait()
	for _, s := range sts {
		if s != 202 && s != 200 {
			t.Fatalf("statuses %v", sts)
		}
	}
	if br.n.Load() != 1 {
		t.Fatalf("%d runs for one key", br.n.Load())
	}
}

func TestSecondWrite409(t *testing.T) {
	br := &blockRunner{release: make(chan struct{})}
	e := newEnv(t, br, nil)
	e.login()
	if st, _ := e.act("w409-key-0001", map[string]string{"action": "noop", "host": "a", "app": "web", "confirm": e.confirmTok("noop", "a", "web")}); st != 202 {
		t.Fatal("first")
	}
	tok := e.confirmTok("noop", "a", "web")
	st, m := e.act("w409-key-0002", map[string]string{"action": "noop", "host": "a", "app": "web", "confirm": tok})
	if st != 409 || errCode(m) != "running" {
		t.Fatalf("second: %d %v", st, m)
	}
	run := m["error"].(map[string]any)["running"].(map[string]any)
	if run["action"] != "noop" || run["since"] == nil || run["key"] != "w409-key-0001" {
		t.Fatalf("409 body: %v", m)
	}
	// another app on the same host is free
	if st, _ := e.act("w409-key-0003", map[string]string{"action": "noop", "host": "a", "app": "shop", "confirm": e.confirmTok("noop", "a", "shop")}); st != 202 {
		t.Fatal("other app blocked")
	}
	close(br.release)
	until(3*time.Second, func() bool { return e.srv.WritesRunning() == 0 })
	// the 409 did not use the token, and its key was not remembered
	if st, m := e.act("w409-key-0002", map[string]string{"action": "noop", "host": "a", "app": "web", "confirm": tok}); st != 202 {
		t.Fatalf("after the first ended: %d %v", st, m)
	}
	if br.n.Load() != 3 {
		t.Fatalf("%d runs", br.n.Load())
	}
}

func TestIdemBounded(t *testing.T) {
	br := &blockRunner{release: make(chan struct{})}
	close(br.release)
	e := newEnv(t, br, func(c *Config) { c.MaxIdem = 10 })
	e.login()
	for i := 0; i < 30; i++ {
		k := "bound-key-" + itoa(1000+i)
		if st, m := e.act(k, map[string]string{"action": "noop", "host": "a", "app": "web", "confirm": e.confirmTok("noop", "a", "web")}); st != 202 {
			t.Fatalf("%d: %d %v", i, st, m)
		}
		until(2*time.Second, func() bool { return e.srv.WritesRunning() == 0 })
	}
	if n := e.srv.idem.count(); n > 10 {
		t.Fatalf("%d records", n)
	}
	ents, _ := os.ReadDir(filepath.Join(e.dir, "cache", "dash-ops"))
	if len(ents) > 10 {
		t.Fatalf("%d op logs", len(ents))
	}
	var f idemFile
	b, _ := os.ReadFile(filepath.Join(e.dir, "cache", "dash-idem.json"))
	json.Unmarshal(b, &f)
	if len(f.Records) > 10 {
		t.Fatalf("%d records on disk", len(f.Records))
	}
}

// a write is not tied to its request: the client going away does not stop it
func TestWriteSurvivesClientGone(t *testing.T) {
	e := newEnv(t, nil, nil) // the fake CLI
	os.WriteFile(filepath.Join(e.fake, "noop-sleep"), []byte("800ms"), 0o600)
	e.login()
	b := `{"action":"noop","host":"a","app":"web","confirm":"` + e.confirmTok("noop", "a", "web") + `"}`
	ctx, cancel := context.WithCancel(context.Background())
	r, _ := http.NewRequestWithContext(ctx, "POST", e.ts.URL+"/api/action", stringsReader(b))
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("Idempotency-Key", "gone-key-0001")
	r.AddCookie(e.cookie)
	resp, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	cancel()
	if !until(5*time.Second, func() bool { _, m := e.get("/api/action?key=gone-key-0001"); return m["status"] == "done" }) {
		_, m := e.get("/api/action?key=gone-key-0001")
		t.Fatalf("write: %v", m)
	}
	_, m := e.get("/api/action?key=gone-key-0001")
	if m["output"] != "tando 0.2.2\n" {
		t.Fatalf("output %v", m)
	}
}
