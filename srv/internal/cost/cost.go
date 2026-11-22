// Package cost is tandod's own cost breakdown: for each part of its work (a check of the
// minute tick, the metrics sample, the log scan, a pass of the live loop, a socket verb) how
// often it ran, the wall time, the CPU of the process while it ran, and the programs it started
// with their CPU. Kept in memory, served by tandod's `cost` verb (tando-status cost); always on:
// a section costs two getrusage calls.
//
// The process CPU of a section is the whole process's while the section ran: the live loop's
// goroutine and a socket reader that ran at the same moment count in it too (a slight
// overstatement, never an understatement). The programs' CPU is that of the children waited for
// in the meantime.
//
// Layer: internal; the standard library only. A nil *Meter does nothing (the one-shot).
package cost

import (
	"slices"
	"sync"
	"syscall"
	"time"
)

// Entry is what one section cost, summed over its runs.
type Entry struct {
	Calls    int64
	Wall     time.Duration
	CPU      time.Duration // the process's (user + system)
	ChildCPU time.Duration // the programs it waited for
	Children int64         // programs started
}

func (e *Entry) add(o Entry) {
	e.Calls += o.Calls
	e.Wall += o.Wall
	e.CPU += o.CPU
	e.ChildCPU += o.ChildCPU
	e.Children += o.Children
}

// Meter holds the breakdown: the last complete tick's sections, and every section's sum since the
// start.
type Meter struct {
	// Started counts the programs the process has started (run.Started); nil: not counted.
	Started func() int64

	mu    sync.Mutex
	start time.Time
	cur   map[string]*Entry // the tick in progress
	last  map[string]Entry  // the last tick that ended
	total map[string]*Entry
	ticks int64
}

// New makes a meter; started counts programs (nil: none counted).
func New(started func() int64) *Meter {
	return &Meter{Started: started, start: time.Now(), cur: map[string]*Entry{}, last: map[string]Entry{},
		total: map[string]*Entry{}}
}

type sample struct {
	at          time.Time
	self, child time.Duration
	started     int64
}

func (m *Meter) now() sample {
	s := sample{at: time.Now()}
	var ru syscall.Rusage
	if syscall.Getrusage(syscall.RUSAGE_SELF, &ru) == nil {
		s.self = tv(ru.Utime) + tv(ru.Stime)
	}
	if syscall.Getrusage(syscall.RUSAGE_CHILDREN, &ru) == nil {
		s.child = tv(ru.Utime) + tv(ru.Stime)
	}
	if m.Started != nil {
		s.started = m.Started()
	}
	return s
}

func tv(t syscall.Timeval) time.Duration {
	return time.Duration(t.Sec)*time.Second + time.Duration(t.Usec)*time.Microsecond
}

// Start begins a section; the func it returns ends it. A nil meter returns a no-op.
func (m *Meter) Start(name string) func() {
	if m == nil {
		return func() {}
	}
	s0 := m.now()
	return func() {
		s1 := m.now()
		e := Entry{Calls: 1, Wall: s1.at.Sub(s0.at), CPU: s1.self - s0.self, ChildCPU: s1.child - s0.child,
			Children: s1.started - s0.started}
		m.mu.Lock()
		defer m.mu.Unlock()
		for _, mp := range []map[string]*Entry{m.cur, m.total} {
			if mp[name] == nil {
				mp[name] = &Entry{}
			}
			mp[name].add(e)
		}
	}
}

// Time runs fn as the section name.
func (m *Meter) Time(name string, fn func()) {
	end := m.Start(name)
	defer end()
	fn()
}

// TickDone closes the tick in progress: its sections become the last tick's.
func (m *Meter) TickDone() {
	if m == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.last = map[string]Entry{}
	for k, e := range m.cur {
		m.last[k] = *e
	}
	m.cur = map[string]*Entry{}
	m.ticks++
}

// Row is one section of a snapshot.
type Row struct {
	Name string
	Entry
}

// Snapshot is the breakdown at one moment: the last tick's sections, every section's sum since
// the start (each sorted by name), the ticks counted and how long the meter has run.
type Snapshot struct {
	Last, Total []Row
	Ticks       int64
	Since       time.Duration
	CPU         time.Duration // the process's CPU since it started
	ChildCPU    time.Duration // its children's
}

// Snapshot copies the breakdown.
func (m *Meter) Snapshot() Snapshot {
	if m == nil {
		return Snapshot{}
	}
	s := m.now()
	m.mu.Lock()
	defer m.mu.Unlock()
	snap := Snapshot{Ticks: m.ticks, Since: s.at.Sub(m.start), CPU: s.self, ChildCPU: s.child}
	for k, e := range m.last {
		snap.Last = append(snap.Last, Row{k, e})
	}
	for k, e := range m.total {
		snap.Total = append(snap.Total, Row{k, *e})
	}
	by := func(a, b Row) int {
		switch {
		case a.Name < b.Name:
			return -1
		case a.Name > b.Name:
			return 1
		}
		return 0
	}
	slices.SortFunc(snap.Last, by)
	slices.SortFunc(snap.Total, by)
	return snap
}
