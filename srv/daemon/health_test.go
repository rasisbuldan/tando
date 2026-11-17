package daemon

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"tando/srv/daemon/proto"
	"tando/srv/internal/kvfile"
)

// healthFiles points the daemon's health files into the test's directory.
func healthFiles(d *Daemon, root string) {
	os.MkdirAll(filepath.Join(root, "runtandod"), 0o700)
	os.MkdirAll(filepath.Join(root, "run"), 0o700)
	d.health = health{ActiveFile: filepath.Join(root, "runtandod/active"), TickFile: filepath.Join(root, "run/tandod.tick"),
		StateFile: filepath.Join(root, "run/tandod.health")}
}

func stateOf(t *testing.T, h *health) map[string]string {
	m, err := kvfile.Load(h.StateFile)
	if err != nil {
		t.Fatal(err)
	}
	return m
}

// A panic in a tick is recovered and counted; the daemon hands the checks to the timer's fallback
// at once (no ActiveFile), records why in StateFile (the "monitor" alert reads it), refuses
// `tick`, keeps serving, and takes the checks back when the retry (an hour later, in time since
// boot) succeeds.
func TestPanicHandsChecksToTheFallback(t *testing.T) {
	d, root := testDaemon(t)
	healthFiles(d, root)
	clock := newFakeClock(time.Unix(1_800_000_000, 0))
	d.Clock = clock
	d.health.start(clock.Now().Unix(), clock.Boot())
	if !exists(d.health.ActiveFile) {
		t.Fatal("not active at the start")
	}
	var boom atomic.Bool
	boom.Store(true)
	d.Watch.Sample = func(context.Context) {
		if boom.Load() {
			var m map[string]int
			m["x"]++ // a nil map: a real bug's panic
		}
	}
	if err := d.Tick(context.Background()); err == nil {
		t.Fatal("a panicking tick reported no error")
	}
	if exists(d.health.ActiveFile) || !d.health.degraded.Load() || d.health.panics.Load() != 1 || exists(d.health.TickFile) {
		t.Errorf("after a panic: active %v degraded %v panics %d", exists(d.health.ActiveFile), d.health.degraded.Load(), d.health.panics.Load())
	}
	if st := stateOf(t, &d.health); st["degraded"] != "1800000000" || !strings.HasPrefix(st["reason"], "panic: ") || st["retry_n"] != "0" {
		t.Errorf("state %v", st)
	}
	if err := d.Tick(context.Background()); !errors.Is(err, errRefuse) {
		t.Errorf("degraded tick: %v", err)
	}
	if p := d.health.problems(); !strings.Contains(p, "1 panics") || !strings.Contains(p, "assignment to entry in nil map") {
		t.Errorf("problems %q", p)
	}
	// the schedule skips; an hour later it retries (30 s into the minute) and takes the checks back
	boom.Store(false)
	d.TimerActive = func(context.Context) bool { return true }
	d.scheduled()
	if d.ticks.Load() != 1 {
		t.Errorf("ticked while degraded")
	}
	clock.set(clock.Now().Add(time.Hour))
	done := make(chan struct{})
	go func() { d.scheduled(); close(done) }()
	<-clock.waiting
	clock.set(clock.wakeAt())
	<-done
	if d.health.degraded.Load() || !exists(d.health.ActiveFile) || stateOf(t, &d.health)["degraded"] != "" {
		t.Errorf("not back after a good retry: %v", stateOf(t, &d.health))
	}
}

// Retries back off: 1 h, 2 h, 4 h, ... at most 24 h, on the boot clock; a wall clock stepped back
// or forward changes nothing.
func TestRetryBackoff(t *testing.T) {
	for n, want := range map[int64]time.Duration{0: time.Hour, 1: 2 * time.Hour, 2: 4 * time.Hour, 4: 16 * time.Hour, 5: 24 * time.Hour, 9: 24 * time.Hour} {
		if got := retryBackoff(n); got != want {
			t.Errorf("retryBackoff(%d) = %v, want %v", n, got, want)
		}
	}
	d, root := testDaemon(t)
	healthFiles(d, root)
	boot := 1000 * time.Second
	d.health.degrade(5, boot, "x")
	if d.health.retryDue(boot + 59*time.Minute) {
		t.Error("retried before an hour")
	}
	if !d.health.retryDue(boot + time.Hour) {
		t.Fatal("no retry after an hour")
	}
	if d.health.retryDue(boot+time.Hour+119*time.Minute) || !d.health.retryDue(boot+time.Hour+2*time.Hour) {
		t.Error("second retry not after 2 h")
	}
}

// A daemon that dies in its tick again and again is degraded once: the state outlives the
// process (StateFile), so a restart neither forgets it nor writes it again.
func TestDegradedOnceAcrossRestarts(t *testing.T) {
	d, root := testDaemon(t)
	healthFiles(d, root)
	h := func() *health {
		return &health{ActiveFile: d.health.ActiveFile, TickFile: d.health.TickFile, StateFile: d.health.StateFile}
	}
	h1 := h()
	h1.start(100, 1000*time.Second)
	h1.begin() // dies
	h2 := h()
	h2.start(160, 1060*time.Second)
	if h2.deaths.Load() != 1 || h2.degraded.Load() || !exists(h2.ActiveFile) {
		t.Fatalf("after one death: deaths %d degraded %v", h2.deaths.Load(), h2.degraded.Load())
	}
	h2.begin() // dies again
	h3 := h()
	h3.start(220, 1120*time.Second)
	if exists(h3.ActiveFile) || !h3.degraded.Load() {
		t.Fatalf("after %d deaths in a row: active %v degraded %v", maxDeaths, exists(h3.ActiveFile), h3.degraded.Load())
	}
	st := stateOf(t, h3)
	h3.begin() // its hourly retry dies too: still degraded since 220, nothing new to tell
	h4 := h()
	h4.start(4000, 5000*time.Second)
	if got := stateOf(t, h4); got["degraded"] != st["degraded"] || !h4.degraded.Load() || exists(h4.ActiveFile) {
		t.Errorf("state %v, was %v", got, st)
	}
}

// A stop asked for (SIGTERM) in the middle of a tick is no death and no failure; a degraded
// daemon restarted on purpose (an upgrade) retries at once.
func TestStopIsNoDeath(t *testing.T) {
	d, root := testDaemon(t)
	healthFiles(d, root)
	d.health.start(100, 1000*time.Second)
	d.health.begin()
	d.health.stop()
	d.health.end(101, 1001*time.Second, context.Canceled, nil, nil)
	d.health.begin() // (killed after TimeoutStopSec, still in a tick)
	h := &health{ActiveFile: d.health.ActiveFile, TickFile: d.health.TickFile, StateFile: d.health.StateFile}
	h.start(130, 1030*time.Second)
	if h.deaths.Load() != 0 || h.failedRun.Load() != 0 || d.health.failedRun.Load() != 0 || !exists(h.ActiveFile) {
		t.Errorf("a stop counted: deaths %d failed %d/%d", h.deaths.Load(), h.failedRun.Load(), d.health.failedRun.Load())
	}
	h.degrade(140, 1040*time.Second, "x")
	h.stop()
	h2 := &health{ActiveFile: d.health.ActiveFile, TickFile: d.health.TickFile, StateFile: d.health.StateFile}
	h2.start(150, 1050*time.Second)
	if !h2.degraded.Load() || !h2.retryDue(1050*time.Second) {
		t.Errorf("a restart on purpose does not retry at once")
	}
}

// Failed ticks: maxFailed in a row degrade; a good one in between resets the count.
func TestFailedTicks(t *testing.T) {
	d, root := testDaemon(t)
	healthFiles(d, root)
	d.health.start(1, time.Second)
	for i, wantDegraded := range []bool{false, false, true} {
		d.health.end(int64(i), time.Second, errors.New("lock busy"), nil, nil)
		if d.health.degraded.Load() != wantDegraded {
			t.Errorf("after %d failures: degraded %v", i+1, d.health.degraded.Load())
		}
	}
	d2, root2 := testDaemon(t)
	healthFiles(d2, root2)
	d2.health.end(1, time.Second, errors.New("x"), nil, nil)
	d2.health.end(2, time.Second, errors.New("x"), nil, nil)
	d2.health.end(3, time.Second, nil, nil, nil)
	d2.health.end(4, time.Second, errors.New("x"), nil, nil)
	if d2.health.degraded.Load() {
		t.Errorf("a good tick did not reset the count")
	}
}

// ActiveFile cannot be written (/run full): the daemon does not tick on its own (the fallback runs
// and asks it: one run a minute), says so, and ticks again on its own once it can write it.
func TestActiveFileUnwritable(t *testing.T) {
	d, root := testDaemon(t)
	healthFiles(d, root)
	d.health.ActiveFile = filepath.Join(root, "no-such-dir", "active")
	d.health.start(1, time.Second)
	d.TimerActive = func(context.Context) bool { return true }
	d.scheduled()
	if d.ticks.Load() != 0 || !strings.Contains(d.health.problems(), "cannot write its active mark") {
		t.Errorf("ticked without its mark: %d; %q", d.ticks.Load(), d.health.problems())
	}
	if err := d.Tick(context.Background()); err != nil || d.ticks.Load() != 1 {
		t.Errorf("a tick asked for (by the fallback): %v", err)
	}
	os.MkdirAll(filepath.Join(root, "no-such-dir"), 0o700)
	d.scheduled()
	if d.ticks.Load() != 2 || !exists(d.health.ActiveFile) {
		t.Errorf("not back: ticks %d", d.ticks.Load())
	}
}

// The watchdog's arithmetic is on time since boot: a tick stuck for good while the wall clock is
// stepped back keeps no watchdog pinging (the review's demonstration), and a wall clock stepped
// forward does not make a fresh tick look stuck.
func TestWatchdogClockSteps(t *testing.T) {
	d, _ := testDaemon(t)
	dir, _ := os.MkdirTemp("/tmp", "wd")
	defer os.RemoveAll(dir)
	n, notes := listenNotify(t, dir)
	d.notify = n
	clock := newFakeClock(time.Unix(1_800_000_000, 0))
	d.Clock = clock
	d.progress.Store(int64(clock.Boot()))                    // a tick began now and hangs
	clock.step(clock.Now().Add(-time.Hour))                  // NTP / an admin steps the clock back
	clock.set(clock.Now().Add(tickTimeout + 10*time.Minute)) // 14 min later in real time, still stuck
	ctx, cancel := context.WithCancel(context.Background())
	go d.watchdog(ctx, 20*time.Millisecond)
	select {
	case m := <-notes:
		t.Errorf("pinged %q while a tick has been stuck for 14 minutes (clock stepped back)", m)
	case <-time.After(300 * time.Millisecond):
	}
	cancel()
	// a fresh tick, the wall clock stepped forward an hour: still pinged
	d2, _ := testDaemon(t)
	dir2, _ := os.MkdirTemp("/tmp", "wd")
	defer os.RemoveAll(dir2)
	n2, notes2 := listenNotify(t, dir2)
	d2.notify = n2
	c2 := newFakeClock(time.Unix(1_800_000_000, 0))
	d2.Clock = c2
	d2.progress.Store(int64(c2.Boot()))
	c2.step(c2.Now().Add(time.Hour))
	ctx2, cancel2 := context.WithCancel(context.Background())
	defer cancel2()
	go d2.watchdog(ctx2, 20*time.Millisecond)
	select {
	case <-notes2:
	case <-time.After(2 * time.Second):
		t.Error("no ping for a fresh tick after a forward clock step")
	}
}

// A panic in a socket verb ends that request with "internal error"; the daemon serves the next.
func TestServerSurvivesAPanickingVerb(t *testing.T) {
	p, stop := testServer(t, 0, func(ctx context.Context, r proto.Request, w io.Writer) error {
		if r.Verb == "show" {
			panic("boom")
		}
		io.WriteString(w, "fine\n")
		return nil
	})
	defer stop()
	a, err := proto.Call(context.Background(), p, proto.Request{Verb: "show"}, time.Second, 5*time.Second)
	if err != nil || a.Err != "internal error" {
		t.Errorf("panicking verb: %+v %v", a, err)
	}
	a, err = proto.Call(context.Background(), p, proto.Request{Verb: "ping"}, time.Second, 5*time.Second)
	if err != nil || string(a.Body) != "fine\n" {
		t.Errorf("after: %+v %v", a, err)
	}
	// a refused tick: closed without an answer, so the client runs the checks itself
	p2, stop2 := testServer(t, 0, func(context.Context, proto.Request, io.Writer) error { return errRefuse })
	defer stop2()
	if _, err := proto.Call(context.Background(), p2, proto.Request{Verb: "tick"}, time.Second, 5*time.Second); err != proto.ErrNoDaemon {
		t.Errorf("refused: %v", err)
	}
}

// Run: the socket, READY and the status text, the schedule; at the end the socket and
// ActiveFile are gone.
func TestRun(t *testing.T) {
	d, root := testDaemon(t)
	healthFiles(d, root)
	sockDir, _ := os.MkdirTemp("/tmp", "rd")
	defer os.RemoveAll(sockDir)
	d.Socket = filepath.Join(sockDir, "s.sock")
	note, notes := listenNotify(t, sockDir)
	d.notify = note
	clock := newFakeClock(time.Unix(1_800_000_010, 0))
	d.Clock = clock
	d.TimerActive = func(context.Context) bool { return true }
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error)
	go func() { done <- d.Run(ctx) }()
	<-clock.waiting
	if m := <-notes; m != "STATUS=idle" {
		t.Errorf("first status %q", m)
	}
	if m := <-notes; m != "READY=1" {
		t.Errorf("ready %q", m)
	}
	clock.set(clock.wakeAt())
	<-clock.waiting // (the tick is over: the schedule sleeps again)
	if d.ticks.Load() != 1 || !exists(d.health.ActiveFile) {
		t.Errorf("ticks %d", d.ticks.Load())
	}
	cancel()
	clock.set(clock.wakeAt())
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if exists(d.Socket) || exists(d.health.ActiveFile) {
		t.Errorf("left behind: socket %v active %v", exists(d.Socket), exists(d.health.ActiveFile))
	}
}

// listenNotify is a fake $NOTIFY_SOCKET.
func listenNotify(t *testing.T, dir string) (notifier, chan string) {
	p := filepath.Join(dir, "notify")
	c, err := net.ListenPacket("unixgram", p)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	ch := make(chan string, 64)
	go func() {
		b := make([]byte, 4096)
		for {
			n, _, err := c.ReadFrom(b)
			if err != nil {
				return
			}
			ch <- string(b[:n])
		}
	}()
	return notifier{addr: p}, ch
}

// The watchdog pings while the schedule makes progress, and stops when it does not (systemd then
// kills and restarts the daemon).
func TestWatchdog(t *testing.T) {
	d, _ := testDaemon(t)
	dir, _ := os.MkdirTemp("/tmp", "wd")
	defer os.RemoveAll(dir)
	n, notes := listenNotify(t, dir)
	d.notify = n
	clock := newFakeClock(time.Unix(1_800_000_000, 0))
	d.Clock = clock
	d.progress.Store(int64(clock.Boot()))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go d.watchdog(ctx, 20*time.Millisecond)
	select {
	case m := <-notes:
		if m != "WATCHDOG=1" {
			t.Errorf("got %q", m)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("no ping while healthy")
	}
	clock.set(clock.Now().Add(tickTimeout + time.Minute)) // stuck
	time.Sleep(60 * time.Millisecond)
	for len(notes) > 0 {
		<-notes
	}
	select {
	case m := <-notes:
		t.Errorf("pinged while stuck: %q", m)
	case <-time.After(200 * time.Millisecond):
	}
}

// statusRows: the rows status gets in-process are the CLI's (here: watch brief).
func TestStatusRowsBrief(t *testing.T) {
	d, root := testDaemon(t)
	os.WriteFile(filepath.Join(root, "lib/watch/state"), []byte("hog.health.st=firing\nhog.health.since=5\nhog.health.det=x\n"), 0o600)
	a := alertRows{d.Watch}
	var b bytes.Buffer
	a.Brief(context.Background(), "hog", &b)
	if b.String() != "alert\thog\thealth\tfiring\t5\tx\n" {
		t.Errorf("brief %q", b.String())
	}
}

func exists(p string) bool { _, err := os.Stat(p); return err == nil }
