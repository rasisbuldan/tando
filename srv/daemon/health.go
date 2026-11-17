package daemon

import (
	"context"
	"errors"
	"fmt"
	"os"
	"runtime/debug"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"tando/srv/internal/atomicfile"
	"tando/srv/internal/decimal"
	"tando/srv/internal/kvfile"
)

// The daemon's own health decides who runs the checks. While it ticks well it keeps
// ActiveFile; the timer's fallback (tando-watch-fallback.service, the one-shot) has
// ConditionPathExists=!ActiveFile, a condition systemd checks itself, with no process. When its
// ticks go wrong it removes the file, stops ticking on its own ("degraded") and refuses `tick`
// over the socket, so the one-shot, which shares none of the daemon's code (the bus, the caches,
// the in-process scan), runs the checks from the next minute on:
//
//   - a panic in a tick: at once (a panic is a bug, and the next one is likely the same);
//   - maxFailed ticks in a row that end with an error;
//   - maxDeaths ticks in a row the process did not survive (an OOM kill, a fatal runtime error,
//     SIGKILL from the watchdog): TickFile, written when a tick starts and removed when it ends,
//     outlives the process (it is in /run/tando-watch, not in tandod's RuntimeDirectory), so the
//     next process knows. A stop asked for (SIGTERM: a restart, host setup) is never a death: the
//     tick is cancelled at once, and StateFile says the stop was asked for.
//
// The degraded state is kept in StateFile (/run/tando-watch: it outlives the process; a reboot
// starts over), so a daemon that dies again and again is degraded once, not once per restart. The
// owner learns it from an alert, not from repeated messages: watch's "monitor" host check reads
// StateFile (and tandod's unit: a daemon restarting before it gets this far) and fires once,
// resolves once, reminds like any alert. A degraded daemon retries one tick after 1 h, then 2 h,
// 4 h, ... at most 24 h, retryDelay into the minute; when one works it takes the checks back. A
// restart asked for (an upgrade) retries at once. A daemon that cannot write ActiveFile (/run
// full) does not tick on its own: the fallback runs and asks it for the tick, one run a minute.
//
// All waiting and timing uses Clock.Boot (never steps); the wall clock only for timestamps.
const (
	maxFailed  = 3
	maxDeaths  = 2
	retryFirst = time.Hour
	retryMax   = 24 * time.Hour
	retryDelay = 30 * time.Second
)

// health is the daemon's record of its ticks.
type health struct {
	ActiveFile string // /run/tandod/active
	TickFile   string // /run/tando-watch/tandod.tick
	StateFile  string // /run/tando-watch/tandod.health

	panics, failedRun, deathsRun, deaths atomic.Int64
	degraded                             atomic.Bool
	activeOK                             atomic.Bool // ActiveFile could be written
	stopping                             atomic.Bool
	mu                                   sync.Mutex
	lastErr                              string
	state                                map[string]string // StateFile
}

func (h *health) setErr(s string) {
	h.mu.Lock()
	h.lastErr = s
	h.mu.Unlock()
}

func (h *health) err() string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.lastErr
}

// saveState writes StateFile (h.mu held).
func (h *health) saveState() {
	if h.StateFile != "" {
		kvfile.Save(h.StateFile, h.state, atomicfile.Mode(0o600))
	}
}

func num(s string) int64 {
	n, _ := decimal.Parse(s, 18)
	return n
}

// start: a stop that was asked for is no death; a tick the last process did not end is one (and
// maxDeaths in a row degrade). A daemon degraded before keeps that state, but one restarted on
// purpose (an upgrade) tries a tick at once.
func (h *health) start(wall int64, boot time.Duration) {
	h.mu.Lock()
	h.state, _ = kvfile.Load(h.StateFile)
	if h.state == nil {
		h.state = map[string]string{}
	}
	asked := h.state["stopping"] == "1"
	delete(h.state, "stopping")
	if h.state["degraded"] != "" {
		h.degraded.Store(true)
		if asked {
			h.state["retry_at"] = decimal.Itoa(int64(boot / time.Second))
		}
	}
	h.saveState()
	h.mu.Unlock()
	if b, err := os.ReadFile(h.TickFile); err == nil {
		os.Remove(h.TickFile)
		if !asked {
			var died int64
			fmt.Sscanf(string(b), "running %d", &died)
			died++
			h.deathsRun.Store(died)
			h.deaths.Add(1)
			h.setErr("a tick did not end: the process died in it")
			if died >= maxDeaths {
				h.degrade(wall, boot, fmt.Sprintf("%d runs in a row did not end (killed, out of memory, or a fatal error)", died))
				return
			}
		}
	}
	if !h.degraded.Load() {
		h.activate()
	}
}

// activate writes ActiveFile; when it cannot (/run full), the daemon leaves its ticks to the
// fallback (shouldTick) and says so.
func (h *health) activate() {
	err := os.WriteFile(h.ActiveFile, nil, 0o600)
	h.activeOK.Store(err == nil)
	if err != nil {
		h.setErr("cannot write " + h.ActiveFile + ": " + err.Error())
	}
}

// shouldTick: the daemon runs the tick of the minute itself (not degraded, ActiveFile written).
// Otherwise the fallback runs, and may ask it for the tick: one run a minute either way.
func (h *health) shouldTick() bool {
	if h.degraded.Load() {
		return false
	}
	if !h.activeOK.Load() {
		h.activate() // (a full /run may have room again)
	}
	return h.activeOK.Load()
}

// begin marks a tick as running (it is still there if the process dies in it).
func (h *health) begin() {
	atomicfile.Write(h.TickFile, []byte(fmt.Sprintf("running %d\n", h.deathsRun.Load())), atomicfile.Mode(0o600))
}

// end records how a tick ended: nil, an error, or a recovered panic (with its stack). A tick
// cancelled because the daemon is stopping is neither good nor bad.
func (h *health) end(wall int64, boot time.Duration, err error, panicked any, stack []byte) {
	os.Remove(h.TickFile)
	h.deathsRun.Store(0)
	switch {
	case panicked != nil:
		h.panics.Add(1)
		msg := fmt.Sprintf("panic: %v", panicked)
		h.setErr(msg)
		journalErr("tandod: a run of the checks panicked: %v\n%s", panicked, stack)
		h.degrade(wall, boot, msg)
	case err != nil && h.stopping.Load() && errors.Is(err, context.Canceled):
	case err != nil:
		n := h.failedRun.Add(1)
		h.setErr(err.Error())
		if n >= maxFailed {
			h.degrade(wall, boot, fmt.Sprintf("%d runs in a row failed, the last: %v", n, err))
		}
	default:
		h.failedRun.Store(0)
		if h.degraded.Swap(false) {
			h.mu.Lock()
			for _, k := range []string{"degraded", "reason", "retry_at", "retry_n"} {
				delete(h.state, k)
			}
			h.saveState()
			h.mu.Unlock()
		}
		h.activate()
	}
}

// degrade hands the checks to the timer's fallback, once: since when, why and the next retry are
// kept in StateFile.
func (h *health) degrade(wall int64, boot time.Duration, why string) {
	os.Remove(h.ActiveFile)
	h.activeOK.Store(false)
	h.degraded.Store(true)
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.state == nil {
		h.state = map[string]string{}
	}
	if h.state["degraded"] == "" {
		h.state["degraded"] = decimal.Itoa(wall)
		h.state["retry_n"] = "0"
		h.state["retry_at"] = decimal.Itoa(int64((boot + retryFirst) / time.Second))
	}
	h.state["reason"] = oneLine(why)
	h.saveState()
}

// retryDue: a degraded daemon's next try has come (and the one after it is set: 1 h, 2 h, 4 h,
// ... at most 24 h, in time since boot).
func (h *health) retryDue(boot time.Duration) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if int64(boot/time.Second) < num(h.state["retry_at"]) {
		return false
	}
	n := num(h.state["retry_n"]) + 1
	h.state["retry_n"] = decimal.Itoa(n)
	h.state["retry_at"] = decimal.Itoa(int64((boot + retryBackoff(n)) / time.Second))
	h.saveState()
	return true
}

func retryBackoff(n int64) time.Duration {
	d := retryFirst
	for i := int64(0); i < n && d < retryMax; i++ {
		d *= 2
	}
	return min(d, retryMax)
}

// stop records that the daemon was asked to stop (before its tick is cancelled).
func (h *health) stop() {
	h.stopping.Store(true)
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.state == nil {
		h.state = map[string]string{}
	}
	h.state["stopping"] = "1"
	h.saveState()
}

// problems for the status text and doctor: "" when there were none since the start.
func (h *health) problems() string {
	var p []string
	if n := h.panics.Load(); n > 0 {
		p = append(p, decimal.Itoa(n)+" panics")
	}
	if n := h.deaths.Load(); n > 0 {
		p = append(p, decimal.Itoa(n)+" died")
	}
	if n := h.failedRun.Load(); n > 0 {
		p = append(p, decimal.Itoa(n)+" failed in a row")
	}
	if !h.activeOK.Load() && !h.degraded.Load() {
		p = append(p, "cannot write its active mark (the timer runs the checks)")
	}
	if len(p) == 0 {
		return ""
	}
	s := "problems: " + strings.Join(p, ", ")
	if e := h.err(); e != "" {
		s += "; last error: " + oneLine(e)
	}
	return s
}

func oneLine(s string) string {
	s = strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return ' '
		}
		return r
	}, s)
	if len(s) > 200 {
		s = s[:200]
	}
	return s
}

// journalErr writes to the journal at priority err ("<3>" on every line: the unit's
// LogLevelMax=notice drops lines without a priority, which count as info).
func journalErr(format string, a ...any) {
	for l := range strings.SplitSeq(strings.TrimRight(fmt.Sprintf(format, a...), "\n"), "\n") {
		fmt.Fprintf(os.Stderr, "<3>%s\n", l)
	}
}

// guard runs fn and turns a panic into a value with its stack.
func guard(fn func() error) (err error, panicked any, stack []byte) {
	defer func() {
		if r := recover(); r != nil {
			panicked, stack = r, debug.Stack()
		}
	}()
	return fn(), nil, nil
}
