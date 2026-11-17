package daemon

import (
	"context"
	"os"
	"testing"
	"time"
)

// A tick stuck for good (it ignores its context) while the wall clock is stepped back one hour:
// the watchdog keeps pinging, so systemd never kills the daemon and ActiveFile stays.
func TestReviewWatchdogClockStepBack(t *testing.T) {
	d, _ := testDaemon(t)
	dir, _ := os.MkdirTemp("/tmp", "wd")
	defer os.RemoveAll(dir)
	n, notes := listenNotify(t, dir)
	d.notify = n
	clock := newFakeClock(time.Unix(1_800_000_000, 0))
	d.Clock = clock
	d.progress.Store(int64(clock.Boot()))                    // a tick began now and hangs (progress is time since boot now)
	clock.set(clock.Now().Add(-time.Hour))                   // NTP / admin steps the clock back
	clock.set(clock.Now().Add(tickTimeout + 10*time.Minute)) // 14 min later in real time, still stuck
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go d.watchdog(ctx, 20*time.Millisecond)
	select {
	case m := <-notes:
		t.Errorf("REVIEW: pinged %q while a tick has been stuck for 14 minutes (clock stepped back)", m)
	case <-time.After(300 * time.Millisecond):
	}
}
