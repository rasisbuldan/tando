package daemon

import (
	"context"
	"sync"
	"testing"
	"time"
)

// fakeClock: the wall clock (Now) and time since boot (Boot) are separate, as on a machine: set
// moves the wall clock and, when it moves forward, time since boot with it (time passed); step
// moves only the wall clock (NTP, an admin). After waits on Boot. waiting receives once per
// After, so the test knows the scheduler sleeps.
type fakeClock struct {
	mu      sync.Mutex
	now     time.Time
	boot    time.Duration
	at      time.Duration // Boot at which the waiter fires
	ch      chan time.Time
	waiting chan struct{}
}

func (c *fakeClock) Boot() time.Duration {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.boot
}

// step moves only the wall clock.
func (c *fakeClock) step(t time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = t
}

func newFakeClock(t time.Time) *fakeClock {
	return &fakeClock{now: t, boot: 1000 * time.Second, waiting: make(chan struct{}, 1)}
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeClock) After(d time.Duration) <-chan time.Time {
	c.mu.Lock()
	c.at, c.ch = c.boot+d, make(chan time.Time, 1)
	ch := c.ch
	c.mu.Unlock()
	c.waiting <- struct{}{}
	return ch
}

// set moves the wall clock to t; forward, that much time passes (Boot too) and a due waiter
// fires; backward is a clock step only.
func (c *fakeClock) set(t time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if d := t.Sub(c.now); d > 0 {
		c.boot += d
	}
	c.now = t
	if c.ch != nil && c.boot >= c.at {
		c.ch <- t
		c.ch = nil
	}
}

// wakeAt is the wall time at which the sleeping scheduler wakes, if no step comes in between.
func (c *fakeClock) wakeAt() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now.Add(c.at - c.boot)
}

func TestScheduleOnMinuteBoundaries(t *testing.T) {
	start := time.Date(2026, 11, 17, 12, 0, 10, 500e6, time.UTC)
	c := newFakeClock(start)
	ctx, cancel := context.WithCancel(context.Background())
	var ticks []time.Time
	tickDur := map[int]time.Duration{2: 150 * time.Second} // the 3rd tick takes 2.5 minutes
	done := make(chan struct{})
	go func() {
		schedule(ctx, c, func() {
			n := len(ticks)
			ticks = append(ticks, c.Now())
			if d := tickDur[n]; d > 0 {
				c.set(c.Now().Add(d))
			}
		}, func() {})
		close(done)
	}()
	step := func() { <-c.waiting; c.set(c.wakeAt()) }
	for range 4 {
		step()
	}
	<-c.waiting
	// a suspend of an hour: one tick at wake-up, then the next minute boundary
	c.set(c.wakeAt().Add(time.Hour + 17*time.Second))
	step()
	<-c.waiting
	cancel()
	c.set(c.wakeAt())
	<-done
	want := []string{"12:01:00", "12:02:00", "12:03:00", "12:06:00", "13:07:17", "13:08:00"}
	if len(ticks) != len(want) {
		t.Fatalf("ticks %v", ticks)
	}
	for i, w := range want {
		if got := ticks[i].Format("15:04:05"); got != w {
			t.Errorf("tick %d at %s, want %s (all: %v)", i, got, w, ticks)
		}
	}
}

func TestNextMinute(t *testing.T) {
	for _, tt := range []struct{ in, want string }{
		{"12:00:00", "12:01:00"}, {"12:00:59.999", "12:01:00"}, {"23:59:30", "00:00:00"},
	} {
		in, _ := time.Parse("15:04:05.999", tt.in)
		if got := nextMinute(in).Format("15:04:05"); got != tt.want {
			t.Errorf("nextMinute(%s) = %s, want %s", tt.in, got, tt.want)
		}
	}
}
