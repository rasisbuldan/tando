package daemon

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"tando/srv/daemon/proto"
	"tando/srv/internal/env"
	"tando/srv/internal/run"
	"tando/srv/watch"
)

// testDaemon: a host without apps in a temp dir, systemctl answered by a func.
func testDaemon(t *testing.T) (*Daemon, string) {
	root := t.TempDir()
	for _, d := range []string{"opt/apps", "lib/watch/out", "run", "units", "proc/1", "proc/self"} {
		os.MkdirAll(filepath.Join(root, d), 0o700)
	}
	os.WriteFile(filepath.Join(root, "proc/uptime"), []byte("1000.0 1\n"), 0o600)
	os.WriteFile(filepath.Join(root, "proc/1/stat"), []byte("1 (init) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 100\n"), 0o600)
	now := time.Unix(1_800_000_000, 0)
	var mu sync.Mutex
	e := env.Env{Root: filepath.Join(root, "opt"), Lib: filepath.Join(root, "lib"), Cgroup: root, Proc: filepath.Join(root, "proc"),
		EUID: 0, Now: func() time.Time { mu.Lock(); defer mu.Unlock(); return now },
		Run: run.Func(func(ctx context.Context, c run.Cmd) ([]byte, error) {
			if c.Argv[0] == "systemctl" && c.Argv[1] == "show" {
				var b strings.Builder
				for i := range c.Argv[4:] {
					if i > 0 {
						b.WriteString("\n")
					}
					b.WriteString("ActiveState=active\nSubState=running\n")
				}
				return []byte(b.String()), nil
			}
			return nil, nil
		})}
	d := &Daemon{Env: e, Clock: realClock{}}
	d.Watch = watch.New(e, 1)
	d.Watch.RunDir, d.Watch.Units, d.Watch.Disks = filepath.Join(root, "run"), filepath.Join(root, "units"), nil
	d.Watch.Cache = watch.NewCache()
	d.Watch.Scan, d.Watch.Sample = nil, nil
	healthFiles(d, root)
	return d, root
}

func TestTickAndVerbs(t *testing.T) {
	d, root := testDaemon(t)
	// an agent notice in the inbox: one event, so the tick commits and writes history
	os.MkdirAll(filepath.Join(root, "lib/watch/inbox"), 0o700)
	os.WriteFile(filepath.Join(root, "lib/watch/inbox/1800000000.hog.x"), []byte("rollback\thog\tx\trolled back\n"), 0o600)
	var b bytes.Buffer
	if err := d.handle(context.Background(), proto.Request{Verb: "tick"}, &b); err != nil {
		t.Fatal(err)
	}
	if d.ticks.Load() != 1 || d.lastTick.Load() == 0 {
		t.Errorf("ticks %d last %d", d.ticks.Load(), d.lastTick.Load())
	}
	b.Reset()
	if err := d.handle(context.Background(), proto.Request{Verb: "history"}, &b); err != nil ||
		!strings.Contains(b.String(), "\trollback\thog\tdeploy\trolled back\n") {
		t.Errorf("history: %v %q", err, b.String())
	}
	b.Reset()
	d.handle(context.Background(), proto.Request{Verb: "ping"}, &b)
	if !strings.HasPrefix(b.String(), "last\t") || !strings.Contains(b.String(), "\tticks\t1\t") {
		t.Errorf("ping %q", b.String())
	}
	if err := d.handle(context.Background(), proto.Request{Verb: "health", Arg: "nope"}, &b); err == nil || err.Error() != "no such app: nope" {
		t.Errorf("health nope: %v", err)
	}
	if err := d.handle(context.Background(), proto.Request{Verb: "status"}, &b); err == nil {
		t.Errorf("status without a collector")
	}
	// the readers' requests are counted for what the monitoring costs (tandod.x), the tick not
	if pid, _, rq := d.selfCounters(); rq != 4 || pid != int64(os.Getpid()) {
		t.Errorf("selfCounters: pid %d requests %d, want 4 (history, ping, health, status)", pid, rq)
	}
}

// Ticks never overlap: two requested at once run one after the other.
func TestTicksDoNotOverlap(t *testing.T) {
	d, _ := testDaemon(t)
	var mu sync.Mutex
	running, most := 0, 0
	d.Watch.Sample = func(context.Context) {
		mu.Lock()
		running++
		most = max(most, running)
		mu.Unlock()
		time.Sleep(50 * time.Millisecond)
		mu.Lock()
		running--
		mu.Unlock()
	}
	var wg sync.WaitGroup
	for range 4 {
		wg.Add(1)
		go func() { defer wg.Done(); d.Tick(context.Background()) }()
	}
	wg.Wait()
	if most != 1 || d.ticks.Load() != 4 {
		t.Errorf("overlap %d, ticks %d", most, d.ticks.Load())
	}
}

// The scheduled tick is skipped while tando-watch.timer is not active (the timer is the switch).
func TestPausedWithTheTimer(t *testing.T) {
	d, _ := testDaemon(t)
	active := false
	d.TimerActive = func(context.Context) bool { return active }
	d.scheduled()
	if d.ticks.Load() != 0 {
		t.Errorf("ticked while the timer is stopped")
	}
	active = true
	d.scheduled()
	if d.ticks.Load() != 1 {
		t.Errorf("did not tick")
	}
}
