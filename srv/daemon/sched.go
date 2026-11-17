package daemon

import (
	"context"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

// Clock is the time of the daemon; tests use a fake one. Two clocks, for two purposes:
//
//   - Now, the wall clock: aligning ticks on minutes, and timestamps (the last tick, history).
//   - Boot, time since boot that never steps (CLOCK_BOOTTIME, from /proc/uptime): everything
//     that measures how long something took or waits for its turn: the watchdog's "is a tick
//     stuck", the retry backoff of a degraded daemon. A step of the wall clock (NTP, an admin, a
//     VM restored) must not make a stuck tick look fresh, or a fresh one stuck. Boot also counts a
//     suspend, and is the same across restarts of the daemon within one boot: values of it kept
//     in /run (a tmpfs, emptied at boot) stay meaningful.
//
// After waits a duration of Boot time.
type Clock interface {
	Now() time.Time
	Boot() time.Duration
	After(d time.Duration) <-chan time.Time
}

type realClock struct{ uptime string } // /proc/uptime

func (realClock) Now() time.Time                         { return time.Now() }
func (realClock) After(d time.Duration) <-chan time.Time { return time.After(d) }

// Boot reads the seconds since boot (10 ms steps). When /proc cannot be read (no file descriptor
// left, say) it goes on from the last value read, by the process's monotonic clock, so the two
// never mix: a watchdog comparing an earlier Boot() with a later one must not see time go back.
func (c realClock) Boot() time.Duration {
	mono := time.Since(processStart)
	if b, err := os.ReadFile(c.uptime); err == nil {
		f, _, _ := strings.Cut(string(b), " ")
		if v, err := strconv.ParseFloat(f, 64); err == nil {
			up := time.Duration(v * float64(time.Second))
			bootOffset.Store(int64(up - mono))
			return up
		}
	}
	return mono + time.Duration(bootOffset.Load())
}

// processStart: the fallback's origin (set once at start; never changed). bootOffset: boot time
// minus the process's clock at the last successful read (0 before the first).
var (
	processStart = time.Now()
	bootOffset   atomic.Int64
)

// nextMinute is the start of the minute after t (the timer's OnCalendar=*-*-* *:*:00).
func nextMinute(t time.Time) time.Time { return t.Truncate(time.Minute).Add(time.Minute) }

// schedule calls tick at the start of every minute until ctx ends. The next start is computed
// from the clock after each tick: a tick that takes longer than a minute skips the minutes it
// overran instead of queueing them, and after a suspend (or a clock step) one tick runs, not one
// per missed minute; nothing drifts, as every wait ends on a minute boundary. Between ticks the
// process sleeps in one timer: no polling.
func schedule(ctx context.Context, c Clock, tick func(), woke func()) {
	for {
		now := c.Now()
		select {
		case <-ctx.Done():
			return
		case <-c.After(nextMinute(now).Sub(now)):
		}
		if ctx.Err() != nil {
			return
		}
		woke()
		tick()
	}
}
