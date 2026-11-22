// Package daemon is tandod: the long-running monitor of a tando host. It composes the domain
// packages in one process (it is the only package besides cmd/* that may import more than one of
// them) and holds no check logic of its own: scheduling, the socket, and the wiring.
//
// Once a minute, while tando-watch.timer is active (the timer stays the on/off switch of the
// checks, and the fallback when tandod is not running), a tick runs what tando-watch.service ran:
// the metrics sample (srv/metrics, in-process), the agent's recover-all when an activation died,
// the checks and their notifications (srv/watch), with the apps' log scan (srv/logs,
// in-process). Between ticks it keeps open a connection to systemd's private bus (systemctl show
// becomes a Get) and a cache of the key=value files it would read again (watch.Cache); the
// durable state of the checks is read from disk every tick, so a kill -9 at any point is as safe
// as the one-shot's (srv/watch commit.go).
//
// Every 5 s, in a goroutine of its own, the live views' point (srv/live: no program, no file, no
// alert state). It serves read-only queries and `tick` on /run/tandod/tandod.sock (package proto); the
// tando-watch CLI asks there first and does the work itself when nothing answers.
//
// Layer: composition. It imports the domain packages (watch, logs, metrics, status, live), daemon/proto
// and internal/*, and holds no check logic and no parsing; only cmd/tandod imports it. It reads no
// environment: main passes what systemd said (Systemd).
package daemon

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"tando/srv/daemon/proto"
	"tando/srv/internal/cost"
	"tando/srv/internal/decimal"
	"tando/srv/internal/env"
	"tando/srv/internal/out"
	"tando/srv/internal/run"
	"tando/srv/internal/sdbus"
	"tando/srv/live"
	"tando/srv/logs"
	"tando/srv/metrics"
	"tando/srv/status"
	"tando/srv/watch"
)

// tickTimeout bounds one tick (its own commands have shorter limits; this catches the rest). It
// stays under WatchdogSec (300 s), so a stuck tick ends before systemd kills the daemon.
const tickTimeout = watch.TickTimeout

// Daemon is tandod.
type Daemon struct {
	Env     env.Env // its Run answers `systemctl show` over the bus
	Watch   watch.Watch
	Metrics metrics.Metrics
	Logs    *logs.Logs
	// Status answers `status [app]` (tando-agent's status verb, srv/status); nil: not served.
	Status *status.Collector
	// Live is the 5 s loop of the live views (srv/live); nil: none (a host without cgroup v2).
	Live   *live.Live
	Socket string
	Clock  Clock
	// TimerActive says whether tando-watch.timer is active: stopped, the daemon runs no ticks of
	// its own (it still answers `tick`).
	TimerActive func(ctx context.Context) bool

	mu       sync.Mutex // one tick at a time (the flock of the watch lock orders it with the one-shot)
	ticks    atomic.Int64
	lastTick atomic.Int64
	progress atomic.Int64    // when the scheduler last made progress (Clock.Boot, ns), for the watchdog
	ticks0   context.Context // what ticks run under: cancelled when the daemon is asked to stop
	notify   notifier
	wdEvery  time.Duration // how often to ping systemd's watchdog (half of WatchdogSec), 0: none
	bus      *busRunner
	health   health
	served   atomic.Int64 // socket requests answered, but ticks: the readers' (selfCounters)
	cost     *cost.Meter  // its cost breakdown by section (the `cost` verb)
}

// selfCounters: tandod's pid, the programs it has started and the readers' requests it has
// answered (srv/metrics writes them a minute at a time, apart from its own cost).
func (d *Daemon) selfCounters() (pid, children, requests int64) {
	return int64(os.Getpid()), run.Started(), d.served.Load()
}

// New wires the daemon for the real machine; sd is what systemd said in the environment.
func New(e env.Env, sd Systemd) *Daemon {
	bus := &busRunner{inner: e.Run, path: sdbus.Socket}
	e.Run = bus
	d := &Daemon{Env: e, Socket: proto.Socket, Clock: realClock{uptime: filepath.Join(e.Proc, "uptime")},
		notify: notifier{addr: sd.NotifySocket}, wdEvery: sd.watchdogInterval(os.Getpid()), bus: bus}
	d.health = health{ActiveFile: ActiveFile, TickFile: "/run/tando-watch/tandod.tick", StateFile: watch.DaemonStateFile}
	d.Watch = watch.New(e, os.Getpid())
	d.Watch.Cache = watch.NewCache()
	d.cost = cost.New(run.Started)
	d.Watch.Cost = d.cost
	d.Metrics = metrics.New(e, "")
	d.Metrics.Self = d.selfCounters // (what the monitoring costs: srv/metrics tandod.x)
	d.Logs = logs.New(e)
	d.Logs.Cache = logs.NewScanCache() // kept across ticks: an idle app costs a few stat calls
	d.Logs.Stderr = os.Stderr
	d.Watch.Scan = logScanner{d.Logs}
	d.Watch.Sample = func(ctx context.Context) { d.Metrics.Sample(ctx) }
	d.Status = status.New(e)
	d.Status.Stderr = io.Discard
	statusRows(d) // (status's rows of logs, watch and metrics in-process: statusrows.go)
	if live.V2(e.Cgroup) {
		d.Live = live.New(e, func(units []string) ([]map[string]string, error) { return bus.get(units, liveProps) })
		d.Live.Cost = d.cost
	}
	d.TimerActive = func(ctx context.Context) bool {
		b, err := e.Run.Output(ctx, runShow("tando-watch.timer"))
		return timerOn(string(b), err)
	}
	return d
}

// ActiveFile exists while tandod runs the checks; tando-watch-fallback.service runs when it does
// not (health.go). In tandod's own RuntimeDirectory (/run/tandod), removed whenever it stops.
const ActiveFile = watch.DaemonActiveFile

// timerOn: the timer is the switch, and only an explicit answer that it is off pauses the
// ticks. When systemd cannot be asked, the daemon goes on (pausing then would leave no checks at
// all: the fallback is skipped while ActiveFile exists).
func timerOn(answer string, err error) bool {
	if err != nil {
		return true
	}
	switch strings.TrimSpace(answer) {
	case "inactive", "failed", "deactivating":
		return false
	}
	return true
}

// logScanner is the in-process scan: srv/logs's WatchScan writes the same rows tando-logs
// watch-scan prints, into memory instead of a pipe.
type logScanner struct{ l *logs.Logs }

func (s logScanner) WatchScan(ctx context.Context) ([]byte, error) {
	var b bytes.Buffer
	w := out.New(&b)
	err := s.l.WatchScan(ctx, nil, w)
	w.Flush()
	return b.Bytes(), err
}

// Run serves until ctx ends (SIGTERM): the socket, the minute schedule, the watchdog. A tick in
// progress is finished first (or ended by systemd's stop timeout: nothing is lost then either).
func (d *Daemon) Run(ctx context.Context) error {
	ln, err := listen(d.Socket)
	if err != nil {
		return err
	}
	// SIGTERM (ctx): first record that the stop was asked for, then cancel the tick running (the
	// commit protocol makes that safe), so a restart is quick and never counted as a death
	ticks, cancelTicks := context.WithCancel(context.Background())
	defer cancelTicks()
	d.ticks0 = ticks
	go func() {
		<-ctx.Done()
		d.health.stop()
		cancelTicks()
	}()
	// (the health state is loaded before the socket answers: a tick asked for in between would run
	// as if the daemon had never been degraded)
	d.progress.Store(int64(d.Clock.Boot()))
	d.health.start(d.Clock.Now().Unix(), d.Clock.Boot())
	srv := newServer(ln, d.handle)
	done := make(chan struct{})
	go func() { srv.serve(ticks); close(done) }()
	d.status("idle")
	d.notify.send("READY=1")
	if d.wdEvery > 0 {
		go d.watchdog(ctx, d.wdEvery)
	}
	if d.Live != nil {
		go d.Live.Run(ticks) // (its own loop: it never waits for a tick, nor a tick for it)
	}
	schedule(ctx, d.Clock, d.scheduledSafe, func() { d.progress.Store(int64(d.Clock.Boot())) })
	d.notify.send("STOPPING=1")
	os.Remove(d.health.ActiveFile)
	ln.Close()
	os.Remove(d.Socket)
	d.mu.Lock() // (waits for a tick in progress)
	d.mu.Unlock()
	<-done
	if d.bus != nil {
		d.bus.close()
	}
	return nil
}

// scheduledSafe is the scheduler's body: nothing in it may end the schedule (a panic outside the
// tick itself is recorded like one in it).
func (d *Daemon) scheduledSafe() {
	if _, p, stack := guard(func() error { d.scheduled(); return nil }); p != nil {
		d.health.end(d.Clock.Now().Unix(), d.Clock.Boot(), nil, p, stack)
		d.status("idle")
	}
}

// scheduled is the tick of the minute, unless the timer is stopped, the daemon handed the checks
// to the timer's fallback (then a retry when its backoff is over, retryDelay into the minute), or
// it cannot write ActiveFile (then the fallback runs and asks it: one run a minute).
func (d *Daemon) scheduled() {
	parent := d.ticks0
	if parent == nil {
		parent = context.Background()
	}
	ctx, cancel := context.WithTimeout(parent, tickTimeout)
	defer cancel()
	if d.TimerActive != nil && !d.TimerActive(ctx) {
		d.status("paused (tando-watch.timer is not active)")
		return
	}
	if d.health.degraded.Load() {
		if !d.health.retryDue(d.Clock.Boot()) {
			d.status("degraded")
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-d.Clock.After(retryDelay):
		}
		d.tick(ctx)
		return
	}
	if !d.health.shouldTick() {
		d.status("idle")
		return
	}
	d.tick(ctx)
}

// errRefuse: the daemon does not run the checks now (degraded): the client runs them itself.
var errRefuse = errors.New("tandod does not run the checks now")

// Tick runs one tick now and returns when it is over (a tick already running is waited for
// first, so the caller sees a sample taken after its request). A degraded daemon refuses.
func (d *Daemon) Tick(ctx context.Context) error {
	if d.health.degraded.Load() {
		return errRefuse
	}
	return d.tick(ctx)
}

func (d *Daemon) tick(ctx context.Context) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	now := d.Clock.Now().Unix()
	d.progress.Store(int64(d.Clock.Boot()))
	d.status("ticking since " + decimal.Itoa(now))
	d.health.begin()
	err, p, stack := guard(func() error {
		testHook()
		return d.Watch.Run(ctx)
	})
	d.health.end(d.Clock.Now().Unix(), d.Clock.Boot(), err, p, stack)
	d.ticks.Add(1)
	if err == nil && p == nil {
		d.lastTick.Store(now)
	}
	d.progress.Store(int64(d.Clock.Boot()))
	d.status("idle")
	if p != nil {
		return errors.New("panic in the checks")
	}
	return err
}

// status publishes the daemon's state in systemd's StatusText: "<state>; last tick <epoch of the
// last good one>; <n> ticks[; degraded][; problems: ...; last error: ...]" (tando-watch's dead
// man's check and doctor read it, without root).
func (d *Daemon) status(s string) {
	if t := d.lastTick.Load(); t > 0 {
		s += "; last tick " + decimal.Itoa(t) + "; " + decimal.Itoa(d.ticks.Load()) + " ticks"
	}
	if d.health.degraded.Load() {
		s += "; degraded: the timer runs the checks"
	}
	if p := d.health.problems(); p != "" {
		s += "; " + p
	}
	d.notify.send("STATUS=" + s)
}

// watchdog pings systemd while the scheduler makes progress: woken every minute, or a tick that
// started less than tickTimeout + 30 s ago, in time since boot (a step of the wall clock must not
// make a stuck tick look fresh).
func (d *Daemon) watchdog(ctx context.Context, iv time.Duration) {
	t := time.NewTicker(iv)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		if time.Duration(int64(d.Clock.Boot())-d.progress.Load()) < tickTimeout+30*time.Second {
			d.notify.send("WATCHDOG=1")
		}
	}
}

// handle answers a socket request with the rows of its verb.
func (d *Daemon) handle(ctx context.Context, r proto.Request, w io.Writer) error {
	if r.Verb != "tick" {
		d.served.Add(1)
	}
	if r.Verb != "tick" && r.Verb != "cost" {
		defer d.cost.Start("socket " + r.Verb)()
	}
	o := out.New(w)
	defer o.Flush()
	var args []string
	if r.Arg != "" {
		args = []string{r.Arg}
	}
	switch r.Verb {
	case "ping":
		o.Row("last", decimal.Itoa(d.lastTick.Load()), "ticks", decimal.Itoa(d.ticks.Load()), "pid", decimal.Itoa(int64(os.Getpid())),
			"goroutines", decimal.Itoa(int64(runtime.NumGoroutine())))
		return nil
	case "tick":
		return d.Tick(ctx)
	case "show":
		return d.Watch.Show(ctx, o, args)
	case "history":
		return d.Watch.History(o, args)
	case "health":
		return d.Watch.Health(o, args)
	case "brief":
		d.Watch.Brief(o, args)
		return nil
	case "live", "ring":
		if d.Live == nil {
			return errNoLive
		}
		if r.Verb == "live" {
			d.Live.Rows(o, r.Arg)
		} else {
			d.Live.RingRows(o, r.Arg)
		}
		return nil
	case "cost":
		costRows(o, d.cost.Snapshot())
		return nil
	case "status":
		if d.Status == nil {
			return errors.New("status is not served here")
		}
		o.Flush()
		return d.Status.Status(ctx, w, r.Arg)
	}
	return proto.ErrBad
}

// errNoLive: the live verbs on a host without the fast loop (cgroup v1 or hybrid).
var errNoLive = errors.New("no live view on this server: it needs cgroup v2 (the per-minute samples still run)")

// liveProps: what the fast loop asks systemd of the loaded app units (the others are not asked).
var liveProps = []sdbus.Prop{{Iface: "org.freedesktop.systemd1.Unit", Name: "ActiveState"},
	{Iface: "org.freedesktop.systemd1.Unit", Name: "SubState"},
	{Iface: "org.freedesktop.systemd1.Service", Name: "NRestarts"},
	{Iface: "org.freedesktop.systemd1.Service", Name: "MainPID"}}

// runShow is `systemctl show -P ActiveState <unit>` (answered over the bus).
func runShow(unit string) run.Cmd {
	return run.Cmd{Argv: []string{"systemctl", "show", "-P", "ActiveState", unit}, Timeout: 20 * time.Second}
}
