package dash

import (
	"context"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// liveRunner: snapshot runs answer {"host":..,"src":"poll"}; follows of host "a" send a line with
// the app row every 20 ms until stopped, the others end at once without a line (no live view).
type liveRunner struct {
	runs, follows atomic.Int32
	aEnded        atomic.Bool
	mu            sync.Mutex
	argv          []string
}

func (r *liveRunner) Run(ctx context.Context, q Req) (Result, error) {
	r.runs.Add(1)
	if len(q.Argv) > 4 && q.Argv[4] == "--app" {
		return Result{Stdout: []byte(`{"host":"a","src":"poll","apps":[],"app":{"name":"web","status":{"app":"web","state":"stale"},"releases":[1]}}`)}, nil
	}
	return Result{Stdout: []byte(`{"host":"` + q.Argv[3] + `","src":"poll"}`)}, nil
}

func (r *liveRunner) Stream(ctx context.Context, q Req, line func([]byte)) (Result, error) {
	r.follows.Add(1)
	if q.Host != "a" {
		return Result{Exit: 3}, nil
	}
	r.mu.Lock()
	r.argv = q.Argv
	r.mu.Unlock()
	defer r.aEnded.Store(true)
	for {
		line([]byte(`{"host":"a","src":"live","server_now":1,"apps":[{"app":"web","state":"running"}],"alerts":[]}` + "\n"))
		select {
		case <-ctx.Done():
			return Result{}, ctx.Err()
		case <-time.After(20 * time.Millisecond):
		}
	}
}

func TestLiveFollow(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	var mu sync.Mutex
	clock := func() time.Time { mu.Lock(); defer mu.Unlock(); return now }
	r := &liveRunner{}
	e := newEnv(t, r, func(c *Config) { c.Now = clock })
	e.login()
	_, m := e.get("/api/overview?visible=1")
	if m["next_poll_s"].(float64) != 5 {
		t.Fatalf("next_poll_s %v, want 5 with live views", m["next_poll_s"])
	}
	if err := waitFor(func() bool {
		_, m := e.get("/api/snapshot?host=a&visible=1")
		return m["data"].(map[string]any)["src"] == "live"
	}); err != nil {
		t.Fatal("no live line answered the poll")
	}
	r.mu.Lock()
	if got := strings.Join(r.argv, " "); got != "snapshot --json --follow -H a" {
		t.Errorf("follow argv %q", got)
	}
	r.mu.Unlock()
	runs := r.runs.Load()
	for i := 0; i < 5; i++ {
		e.get("/api/snapshot?host=a&visible=1")
	}
	if r.runs.Load() != runs {
		t.Errorf("polls ran snapshot (%d runs) while the live line was fresh", r.runs.Load()-runs)
	}
	// an app's page: its own snapshot, the live row laid over it
	_, m = e.get("/api/snapshot?host=a&app=web&visible=1")
	app := m["data"].(map[string]any)["app"].(map[string]any)
	if app["status"].(map[string]any)["state"] != "running" || app["releases"] == nil || m["data"].(map[string]any)["src"] != "live" {
		t.Errorf("app snapshot with the live row: %v", m["data"])
	}
	// a server without a live view: polled, its follow not started again for a while
	// (the overview started one per server: b's ended at once)
	f := r.follows.Load()
	for i := 0; i < 3; i++ {
		e.get("/api/snapshot?host=b&visible=1")
	}
	if _, m := e.get("/api/snapshot?host=b&visible=1"); m["data"].(map[string]any)["src"] != "poll" || r.follows.Load() != f {
		t.Errorf("no live view: %v, follows %d -> %d", m["data"], f, r.follows.Load())
	}
	// no visible page for 30 s: the follow of a ends
	mu.Lock()
	now = now.Add(31 * time.Second)
	mu.Unlock()
	if err := waitFor(r.aEnded.Load); err != nil {
		t.Error("the follow did not end without a visible page")
	}
	mu.Lock()
	now = now.Add(13 * time.Second) // (its last line, up to 12 s old, still answered until now)
	mu.Unlock()
	if _, m := e.get("/api/snapshot?host=a&visible=0"); m["data"].(map[string]any)["src"] != "poll" {
		t.Errorf("a hidden page after the follow ended: %v", m["data"])
	}
}

func waitFor(f func() bool) error {
	for end := time.Now().Add(5 * time.Second); time.Now().Before(end); time.Sleep(10 * time.Millisecond) {
		if f() {
			return nil
		}
	}
	return context.DeadlineExceeded
}

func TestLiveOver(t *testing.T) {
	got := string(liveOver([]byte(`{"host":"a","x":1,"apps":[],"app":{"name":"web","status":{"app":"web","mem":1},"releases":[]}}`),
		[]byte(`{"host":"a","server_now":9,"apps":[{"app":"api"},{"app":"web","mem":2}]}`), "web"))
	if !strings.Contains(got, `"server_now":9`) || !strings.Contains(got, `"status":{"app":"web","mem":2}`) ||
		!strings.Contains(got, `"releases":[]`) || !strings.Contains(got, `"x":1`) {
		t.Errorf("liveOver: %s", got)
	}
}
