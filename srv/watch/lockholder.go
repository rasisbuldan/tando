package watch

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"tando/srv/internal/decimal"
	"tando/srv/internal/lock"
)

// The lock of the checks ($V/lock) orders runs, tandod's ticks and the verbs that change the
// state. A process that holds it for good (stuck on something that ignores every timeout) would
// stop every check, tandod's and the timer's alike, without a word: tandod degrades, the
// fallback cannot run either, and the "monitor" alert needs a run to be sent. So whoever takes
// the lock writes $V/lock.holder ("<pid> <process start> <since>"), and a run that cannot get the
// lock reads it: held longer than the tick budget and a margin, the run says so where it does not
// need the lock: an error in the journal, a fail row in tando doctor, and a message straight to
// the notifiers (at most once an hour, kept in $V/lockstuck.told).
const stuckAfter = TickTimeout + 60*time.Second

// heldLock is the lock of the checks with its holder record.
type heldLock struct {
	l    *lock.Lock
	path string
	me   string
}

func (w Watch) holderPath() string { return filepath.Join(w.Dir, "lock.holder") }

// takeLock takes the lock of the checks, waiting up to timeout, and records the holder.
func (w Watch) takeLock(timeout time.Duration) (*heldLock, error) {
	l, err := lock.Acquire(w.lockPath(), timeout)
	if err != nil {
		return nil, err
	}
	me := selfHolder(w.Env.Proc, w.now())
	// (a note for a stuck lock, not state: no fsync, every tick; written under the lock, so no
	// reader sees half of it but a stuck-lock check, which then ignores it)
	if f, err := os.OpenFile(w.holderPath(), os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600); err == nil {
		f.WriteString(me + "\n")
		f.Close()
	}
	return &heldLock{l: l, path: w.holderPath(), me: me}, nil
}

// Release removes the holder record (if it is still ours) and the lock.
func (h *heldLock) Release() error {
	if b, err := os.ReadFile(h.path); err == nil && strings.TrimSpace(string(b)) == h.me {
		os.Remove(h.path)
	}
	return h.l.Release()
}

// selfHolder is "<pid> <start time of the process, clock ticks since boot> <now>".
func selfHolder(proc string, now int64) string {
	pid := os.Getpid()
	return decimal.Itoa(int64(pid)) + " " + procStart(proc, pid) + " " + decimal.Itoa(now)
}

// procStart is field 22 of /proc/<pid>/stat ("" when there is no such process).
func procStart(proc string, pid int) string {
	b, err := os.ReadFile(filepath.Join(proc, decimal.Itoa(int64(pid)), "stat"))
	if err != nil {
		return ""
	}
	s := string(b)
	if i := strings.LastIndex(s, ") "); i >= 0 {
		s = s[i+2:]
	}
	f := strings.Fields(s)
	if len(f) > 19 {
		return f[19]
	}
	return ""
}

// stuckHolder: the lock's holder as recorded, and whether it looks stuck (alive, the same
// process, holding it longer than stuckAfter). ok false: no record, or not stuck.
func (w Watch) stuckHolder(now int64) (desc string, stuck bool) {
	b, err := os.ReadFile(w.holderPath())
	if err != nil {
		return "", false
	}
	f := strings.Fields(string(b))
	if len(f) != 3 {
		return "", false
	}
	pid, _ := decimal.Parse(f[0], 9)
	since, _ := decimal.Parse(f[2], 18)
	held := now - since
	if held < int64(stuckAfter/time.Second) {
		return "", false
	}
	start := procStart(w.Env.Proc, int(pid))
	if start == "" || start != f[1] {
		return "", false // that process is gone: the record is old (whoever holds the lock now has not run long)
	}
	comm := strings.TrimSpace(readFirst(filepath.Join(w.Env.Proc, f[0], "comm")))
	return fmt.Sprintf("held for %s by pid %s (%s)", dur(held), f[0], or(comm, "?")), true
}

// lockStuck is said when a run cannot get the lock: if the holder looks stuck, in the journal,
// and to every notifier straight away (no queue, no state: both need the lock), once an hour.
func (w Watch) lockStuck(ctx context.Context, cfg settings) {
	now := w.now()
	desc, stuck := w.stuckHolder(now)
	if !stuck {
		return
	}
	fmt.Fprintf(os.Stderr, "<3>tando-watch: the lock of the checks is %s: no checks run (sudo kill it)\n", desc)
	told := filepath.Join(w.Dir, "lockstuck.told") // (the time it was last told)
	if t, ok := decimal.Parse(strings.TrimSpace(readFirst(told)), 18); ok && now-t < 3600 && now >= t {
		return
	}
	os.WriteFile(told, []byte(decimal.Itoa(now)+"\n"), 0o600)
	tmp, err := os.CreateTemp(w.RunDir, "stuck.")
	if err != nil {
		return
	}
	tmp.WriteString(message{"monitor", "host", "lock", clean("no checks run: the lock of the checks is " + desc +
		"; on the server: sudo kill it, or reboot"), now}.line())
	tmp.Close()
	m := w.compose(cfg, []string{tmp.Name()})
	os.Remove(tmp.Name())
	for _, n := range w.notifiers() {
		w.notifier(n).Send(ctx, m)
	}
}
