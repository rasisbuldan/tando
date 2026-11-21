package dash

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestSnapshotCacheAndPollHint(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	var mu sync.Mutex
	clock := func() time.Time { mu.Lock(); defer mu.Unlock(); return now }
	var n atomic.Int32
	var argvs []string
	r := FuncRunner(func(ctx context.Context, q Req) (Result, error) {
		n.Add(1)
		mu.Lock()
		argvs = append(argvs, strings.Join(q.Argv, " "))
		mu.Unlock()
		return Result{Stdout: []byte(`{"host":"a","new_field":[1,2]}`)}, nil
	})
	e := newEnv(t, r, func(c *Config) { c.Now = clock })
	e.login()
	st, m := e.get("/api/snapshot?host=a&visible=1")
	if st != 200 || m["cached"] != false || m["next_poll_s"].(float64) != 15 {
		t.Fatalf("%d %v", st, m)
	}
	if d := m["data"].(map[string]any); d["new_field"] == nil {
		t.Fatal("data not passed through")
	}
	st, m = e.get("/api/snapshot?host=a&visible=0")
	if st != 200 || m["cached"] != true || m["next_poll_s"].(float64) != 60 || n.Load() != 1 {
		t.Fatalf("cached: %d %v runs=%d", st, m, n.Load())
	}
	// another key runs
	e.get("/api/snapshot?host=a&app=web&range=7d")
	e.get("/api/snapshot?host=a&app=web&range=24h")
	// the Server page: the host's series over a range, without an app
	if st, _ := e.get("/api/snapshot?host=a&range=24h"); st != 200 {
		t.Fatalf("host range: %d", st)
	}
	if n.Load() != 4 {
		t.Fatalf("runs %d", n.Load())
	}
	mu.Lock()
	if argvs[1] != "snapshot --json -H a --app web --range 7d" {
		t.Fatalf("argv %q", argvs[1])
	}
	if argvs[3] != "snapshot --json -H a --range 24h" {
		t.Fatalf("host range argv %q", argvs[3])
	}
	mu.Unlock()
	// after 10 s it runs again
	mu.Lock()
	now = now.Add(11 * time.Second)
	mu.Unlock()
	if _, m := e.get("/api/snapshot?host=a"); m["cached"] != false || n.Load() != 5 {
		t.Fatalf("after ttl: %v %d", m, n.Load())
	}
}

func TestSingleFlight(t *testing.T) {
	var n atomic.Int32
	release := make(chan struct{})
	r := FuncRunner(func(ctx context.Context, q Req) (Result, error) {
		n.Add(1)
		select {
		case <-release:
		case <-ctx.Done():
			return Result{}, ctx.Err()
		}
		return Result{Stdout: []byte(`{"ok":true}`)}, nil
	})
	e := newEnv(t, r, nil)
	e.login()
	var wg sync.WaitGroup
	codes := make([]int, 20)
	for i := range codes {
		wg.Add(1)
		go func() { defer wg.Done(); codes[i], _ = e.get("/api/snapshot?host=b") }()
	}
	until(2*time.Second, func() bool { f, _ := e.srv.snaps.stats(); _ = f; return n.Load() == 1 })
	time.Sleep(100 * time.Millisecond)
	close(release)
	wg.Wait()
	for _, c := range codes {
		if c != 200 {
			t.Fatalf("codes %v", codes)
		}
	}
	if n.Load() != 1 {
		t.Fatalf("%d runs for 20 identical requests", n.Load())
	}
}

// the shared run is cancelled only when its last waiter goes away
func TestSingleFlightCancelWhenAllGone(t *testing.T) {
	var cancelled atomic.Int32
	r := FuncRunner(func(ctx context.Context, q Req) (Result, error) {
		<-ctx.Done()
		cancelled.Add(1)
		return Result{}, ctx.Err()
	})
	e := newEnv(t, r, nil)
	e.login()
	ctx1, c1 := context.WithCancel(context.Background())
	ctx2, c2 := context.WithCancel(context.Background())
	go e.req(ctx1, "GET", "/api/snapshot?host=c", nil)
	go e.req(ctx2, "GET", "/api/snapshot?host=c", nil)
	time.Sleep(300 * time.Millisecond)
	c1()
	time.Sleep(300 * time.Millisecond)
	if cancelled.Load() != 0 {
		t.Fatal("cancelled while a waiter remains")
	}
	c2()
	if !until(3*time.Second, func() bool { return cancelled.Load() == 1 }) {
		t.Fatal("not cancelled after the last waiter left")
	}
}

func TestOverviewPartialAndMenubarCache(t *testing.T) {
	e := newEnv(t, nil, nil) // the fake CLI: a, b, c ok; fail1, garbage1, ... fail
	// keep the hosts that answer fast
	for _, h := range []string{"slow1", "hang1", "midkill1", "big1"} {
		os.Remove(filepath.Join(e.dir, "hosts", h))
	}
	e.login()
	st, m := e.get("/api/overview?visible=1")
	if st != 200 {
		t.Fatalf("%d %v", st, m)
	}
	hosts := m["hosts"].([]any)
	got := map[string]map[string]any{}
	for _, h := range hosts {
		hm := h.(map[string]any)
		got[hm["host"].(string)] = hm
	}
	for _, h := range []string{"a", "b", "c", "ok1"} {
		if got[h]["ok"] != true || got[h]["data"] == nil {
			t.Errorf("%s: %v", h, got[h])
		}
	}
	if errCode(got["fail1"]) != "cli" || !strings.Contains(got["fail1"]["error"].(map[string]any)["message"].(string), "Connection refused") {
		t.Errorf("fail1: %v", got["fail1"])
	}
	if errCode(got["garbage1"]) != "bad_output" {
		t.Errorf("garbage1: %v", got["garbage1"])
	}
	// the menu bar's cache: ls --all --json's shape, atomic, 0600
	p := filepath.Join(e.dir, "cache", "ls-all.json")
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	fi, _ := os.Stat(p)
	if fi.Mode().Perm() != 0o600 {
		t.Errorf("mode %v", fi.Mode())
	}
	var ls struct {
		Hosts []struct {
			Host   string
			Apps   []struct{ App, State, Link string }
			Alerts []map[string]any
			Error  *string
		}
	}
	if err := json.Unmarshal(b, &ls); err != nil {
		t.Fatal(err)
	}
	seen := 0
	for _, h := range ls.Hosts {
		switch h.Host {
		case "a":
			seen++
			if len(h.Apps) != 2 || h.Apps[0].App != "web" || h.Apps[0].Link == "" || h.Apps[1].App != "api" || len(h.Alerts) != 1 || h.Error != nil {
				t.Errorf("a: %+v", h)
			}
		case "fail1":
			seen++
			if h.Error == nil || !strings.Contains(*h.Error, "refused") {
				t.Errorf("fail1: %+v", h)
			}
		}
	}
	if seen != 2 {
		t.Fatalf("ls-all: %s", b)
	}
	if ents, _ := os.ReadDir(filepath.Join(e.dir, "cache")); len(ents) > 0 {
		for _, en := range ents {
			if strings.HasPrefix(en.Name(), ".tmp-") {
				t.Errorf("temp file left: %s", en.Name())
			}
		}
	}
}

// a host that hangs does not hold the overview past the per-host timeout
func TestOverviewPerHostTimeout(t *testing.T) {
	e := newEnv(t, nil, func(c *Config) { c.ReadTimeout = 3 * time.Second })
	for _, h := range []string{"slow1", "midkill1", "big1", "garbage1", "fail1", "ok1", "b", "c"} {
		os.Remove(filepath.Join(e.dir, "hosts", h))
	}
	e.login()
	t0 := time.Now()
	st, m := e.get("/api/overview")
	if st != 200 || time.Since(t0) > 8*time.Second {
		t.Fatalf("%d after %v", st, time.Since(t0))
	}
	for _, h := range m["hosts"].([]any) {
		hm := h.(map[string]any)
		if hm["host"] == "hang1" && errCode(hm) != "timeout" {
			t.Errorf("hang1: %v", hm)
		}
		if hm["host"] == "a" && hm["ok"] != true {
			t.Errorf("a: %v", hm)
		}
	}
}

func TestDoctorRateLimit(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	var mu sync.Mutex
	clock := func() time.Time { mu.Lock(); defer mu.Unlock(); return now }
	var n atomic.Int32
	r := FuncRunner(func(ctx context.Context, q Req) (Result, error) {
		n.Add(1)
		if q.Host == "fail1" {
			return Result{}, &CLIError{Code: "cli", Msg: "ssh refused"}
		}
		return Result{Stdout: []byte(`{"checks":[]}`)}, nil
	})
	e := newEnv(t, r, func(c *Config) { c.Now = clock })
	e.login()
	for i := 0; i < 5; i++ {
		st, m := e.get("/api/doctor?host=a")
		if st != 200 {
			t.Fatal(st, m)
		}
		if i > 0 && (m["cached"] != true || m["next_run_s"].(float64) != 60) {
			t.Fatalf("%v", m)
		}
	}
	e.get("/api/hoststatus?host=a")
	if n.Load() != 2 {
		t.Fatalf("runs %d", n.Load())
	}
	// a failure counts too
	e.get("/api/doctor?host=fail1")
	if st, _ := e.get("/api/doctor?host=fail1"); st != 502 || n.Load() != 3 {
		t.Fatalf("fail: %d runs %d", st, n.Load())
	}
	mu.Lock()
	now = now.Add(61 * time.Second)
	mu.Unlock()
	if _, m := e.get("/api/doctor?host=a"); m["cached"] != false || n.Load() != 4 {
		t.Fatalf("after a minute: %v %d", m, n.Load())
	}
}

// the cache stays bounded
func TestCacheBounded(t *testing.T) {
	c := newCache(5, false)
	for i := 0; i < 50; i++ {
		k := string(rune('a'+i%26)) + string(rune('a'+i/26))
		c.get(context.Background(), context.Background(), k, time.Minute, time.Second, time.Now,
			func(context.Context) (json.RawMessage, error) { return json.RawMessage(`{}`), nil })
	}
	if n, _ := c.stats(); n > 5 {
		t.Fatalf("%d entries", n)
	}
}
