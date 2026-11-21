package dash

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// TestSoak: polling with injected faults (slow, hang, garbage, non-zero exit, killed
// mid-stream, too large) and writes, for 2 minutes (TANDO_DASH_SOAK=30m for the long one;
// skipped with -short). Goroutines, heap and RSS must stay flat; nothing may be left running.
func TestSoak(t *testing.T) {
	if testing.Short() {
		t.Skip("soak: not with -short")
	}
	dur := 2 * time.Minute
	if v := os.Getenv("TANDO_DASH_SOAK"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			t.Fatal(err)
		}
		dur = d
	}
	e := newEnv(t, nil, func(c *Config) {
		c.CacheTTL = 300 * time.Millisecond // many more runs than the real 10 s
		c.HostCareTTL = 2 * time.Second
		c.ReadTimeout = 2 * time.Second
	})
	os.WriteFile(filepath.Join(e.fake, "noop-sleep"), []byte("50ms"), 0o600)
	e.login()
	hosts := []string{"a", "b", "ok1", "slow1", "hang1", "garbage1", "fail1", "midkill1", "big1"}

	sample := func() (g int, heap uint64, rss int) {
		// keep-alive connections are not leaks: close them, and let their goroutines end
		noRedirect.CloseIdleConnections()
		e.ts.CloseClientConnections()
		prev := -1
		until(10*time.Second, func() bool {
			n := runtime.NumGoroutine()
			same := n == prev
			prev = n
			time.Sleep(200 * time.Millisecond)
			return same && n < 20
		})
		runtime.GC()
		runtime.GC()
		var ms runtime.MemStats
		runtime.ReadMemStats(&ms)
		out, _ := exec.Command("ps", "-o", "rss=", "-p", strconv.Itoa(os.Getpid())).Output()
		rss, _ = strconv.Atoi(strings.TrimSpace(string(out)))
		return runtime.NumGoroutine(), ms.HeapInuse, rss
	}

	var reqs, errs atomic.Int64
	// load: one phase of polling and writes, for d
	load := func(d time.Duration) {
		ctx, cancel := context.WithTimeout(context.Background(), d)
		defer cancel()
		var wg sync.WaitGroup
		poll := func(path string, every time.Duration) {
			defer wg.Done()
			for ctx.Err() == nil {
				st, _, _ := e.req(ctx, "GET", path, nil)
				reqs.Add(1)
				if st != 200 {
					errs.Add(1)
				}
				select {
				case <-ctx.Done():
				case <-time.After(every):
				}
			}
		}
		for i := 0; i < 3; i++ { // three tabs
			wg.Add(1)
			go poll("/api/overview?visible=1", 400*time.Millisecond)
			for _, h := range hosts {
				wg.Add(1)
				go poll("/api/snapshot?host="+h+"&app=web&range=24h&visible=1", 300*time.Millisecond)
			}
			wg.Add(1)
			go poll("/api/doctor?host=a", time.Second)
		}
		// tabs that close mid-request (client disconnect)
		wg.Add(1)
		go func() {
			defer wg.Done()
			for ctx.Err() == nil {
				c, cc := context.WithTimeout(ctx, 150*time.Millisecond)
				e.req(c, "GET", "/api/snapshot?host=slow1", nil)
				cc()
			}
		}()
		// writes, each sent twice (replay)
		wg.Add(1)
		go func() {
			defer wg.Done()
			for ctx.Err() == nil {
				k := "soak-key-" + strconv.FormatInt(time.Now().UnixNano(), 10)
				b := map[string]string{"action": "noop", "host": "a", "app": "web", "confirm": e.confirmTok("noop", "a", "web")}
				e.act(k, b)
				e.act(k, b)
				select {
				case <-ctx.Done():
				case <-time.After(200 * time.Millisecond):
				}
			}
		}()
		wg.Wait()
		until(10*time.Second, func() bool { return e.lim.Running() == 0 && e.srv.WritesRunning() == 0 })
		time.Sleep(time.Second) // keep-alive connections settle
	}
	// two equal phases; quiet samples after each must match
	load(dur / 2)
	g0, h0, r0 := sample()
	load(dur / 2)
	g1, h1, r1 := sample()
	t.Logf("soak %v: %d requests (%d not 200, faults included); after phase 1 / phase 2: goroutines %d / %d, heap %d / %d KB, RSS %d / %d KB",
		dur, reqs.Load(), errs.Load(), g0, g1, h0>>10, h1>>10, r0, r1)
	if reqs.Load() < 100 {
		t.Fatalf("only %d requests", reqs.Load())
	}
	if g1 > g0+3 {
		t.Errorf("goroutines grew: %d -> %d", g0, g1)
	}
	if h1 > h0*3/2+(4<<20) {
		t.Errorf("heap grew: %d -> %d", h0, h1)
	}
	if r0 > 0 && r1 > r0*5/4+10<<10 {
		t.Errorf("RSS grew: %d KB -> %d KB", r0, r1)
	}
	if n, _ := e.srv.snaps.stats(); n > e.srv.cfg.MaxCache {
		t.Errorf("cache %d entries", n)
	}
	// A live follow (`snapshot --json --follow`, live.go) is not a leak: polls with visible=1 keep
	// one per host running by design, and it ends liveLinger after the last such poll (its
	// ticker is one second, and under CPU load the sample above may have taken most of that
	// time). Wait for it, by polling, before asking for "nothing left".
	until(liveLinger+15*time.Second, func() bool { return e.lim.Running() == 0 && e.srv.inflight.Load() == 0 })
	if e.lim.Running() != 0 || e.srv.inflight.Load() != 0 {
		t.Errorf("left: %d children, %d requests", e.lim.Running(), e.srv.inflight.Load())
	}
	// no hang child or grandchild left
	if pid := readPid(filepath.Join(e.fake, "hang1.pid")); pid > 0 {
		checkGone(t, e.fake, "hang1")
	}
}
