package watch

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"

	"tando/srv/internal/apps"
	"tando/srv/internal/decimal"
	"tando/srv/internal/fsinfo"
	"tando/srv/internal/lock"
	"tando/srv/internal/systemd"
)

// tick is one run: the clock, the settings, the stores, the facts read once, and what the
// checks decided.
type tick struct {
	w   *Watch
	ctx context.Context
	now int64
	cfg settings
	st  *store // durable state (W)
	vs  *store // volatile state (VS)

	host     map[string]string            // host.conf
	units    map[string]map[string]string // app name (or "_caddy") -> systemctl show properties
	appUnits map[string]bool              // tando-<app>.service of every app with a unit
	holdAll  bool                         // booting, or systemd did not answer: apps not judged
	caddyUp  bool
	names    []string            // every app (with or without a release)
	jobs     map[string][]string // app -> the scheduled jobs of its live release (check_jobs.go)
	workers  map[string][]string // app -> the workers of its live release (check_workers.go)
	again    map[string]bool     // firing checks that failed anew this run: told again (a job's next failed run)
	pg       *pgFacts            // what PostgreSQL answered this run (nil: not asked, or no answer)
	oomUnits map[string]bool     // units the journal names for this run's OOM kills
	apps     []*appTick

	events   []event
	out      []message
	resolved map[string]string // why a check resolved this run (the "resolved" message)
	recover  map[string]int64  // health_recover of an app (tando.conf), by key
	inbox    []string          // notices turned into events: deleted when the run commits
}

// appTick is one app in this run.
type appTick struct {
	name          string
	conf, state   map[string]string
	unit          map[string]string // its systemctl show properties (nil for a static app)
	hasUnit       bool              // not static (Caddy serves static apps' files)
	stopped, hold bool
	down          string // ok, bad, hold, stopped, nounit
	newRestarts   int64
	exitInfo      string // how its main process last ended
	class         string // this minute for the uptime record: ok, down, hold, stopped, ... [ms]
	probeURL      string // queued health probe
}

func (a *appTick) key(c string) string { return a.name + "." + c }

// unitProps are what one systemctl call reads for every app and Caddy.
// (InactiveEnterTimestampMonotonic is for the job units: when a run ended, check_jobs.go)
var unitProps = []string{"ActiveState", "SubState", "Result", "NRestarts", "MemoryMax", "ExecMainCode", "ExecMainStatus",
	"InactiveEnterTimestampMonotonic"}

// Run is the verb `run`: one check run under the lock, then delivery outside it.
func (w Watch) Run(ctx context.Context) error {
	if err := needRoot(w.Env); err != nil {
		return err
	}
	w.pretick(ctx)
	w.sweepTemp()
	l, err := w.takeLock(30 * time.Second)
	if errors.Is(err, lock.ErrBusy) {
		w.lockStuck(ctx, loadSettingsC(w.Cache, w.Conf)) // (held for good? said where no lock is needed)
		return errf("another run holds the lock")
	}
	if err != nil {
		return err
	}
	t := w.newTick(ctx)
	if err := os.MkdirAll(w.RunDir, 0o700); err == nil {
		os.Chmod(w.RunDir, 0o700)
	}
	t.vs = newStore(loadQuiet(w.vstatePath()))
	w.recoverCommit(t.st) // a run killed after its commit point: finish what it decided
	t.check()
	err = t.commit()
	if err == nil {
		w.newErrorsCommitted()
	}
	t.vs.set("last", decimal.Itoa(t.now))
	if t.vs.dirty {
		t.vs.save(w.vstatePath())
	}
	l.Release()
	if err != nil {
		return err
	}
	w.deliver(ctx, t.cfg, t.vs, t.now)
	if t.vs.dirty {
		t.vs.save(w.vstatePath())
	}
	return nil
}

func (w *Watch) newTick(ctx context.Context) *tick {
	host, _ := w.Cache.load(filepath.Join(w.Env.Root, "host.conf"))
	return &tick{
		w: w, ctx: ctx, now: w.now(),
		cfg:      loadSettingsC(w.Cache, w.Conf),
		st:       loadState(w.statePath()),
		vs:       newStore(nil),
		host:     host,
		units:    map[string]map[string]string{},
		appUnits: map[string]bool{},
		oomUnits: map[string]bool{},
		jobs:     map[string][]string{},
		workers:  map[string][]string{},
		again:    map[string]bool{},
		resolved: map[string]string{},
		recover:  map[string]int64{},
	}
}

// check runs every check of the tick and decides what to send.
func (t *tick) check() {
	t.readInbox()
	t.checkBoot()
	names := t.findApps()
	t.names = names
	for _, c := range firstChecks() {
		c.check(t)
	}
	for _, a := range names {
		at := t.loadApp(a)
		if at == nil {
			continue // nothing deployed: nothing to watch
		}
		t.apps = append(t.apps, at)
		for _, c := range appCheckList() {
			c.check(t, at)
		}
	}
	for _, c := range lastChecks() {
		c.check(t)
	}
	t.forgetRemoved()
	t.reconcile()
}

// checkBoot: the host restarted? App checks wait boot_grace while it settles; one notice.
func (t *tick) checkBoot() {
	bt := t.w.bootTime(t.now)
	age := t.now - bt
	if b := t.st.get("_boot"); b != "" {
		if d := bt - num(b, 0); d > 60 || d < -60 {
			if t.cfg.str("notify_reboot") == "yes" {
				t.event("reboot", "_host", "reboot", "the host restarted "+dur(age)+" ago")
			}
			t.st.set("_boot", decimal.Itoa(bt))
		}
	} else {
		t.st.set("_boot", decimal.Itoa(bt))
	}
	if age < t.cfg.num("boot_grace", "") {
		t.holdAll = true
	}
}

// findApps lists the apps and asks systemd about every app unit, every job unit and Caddy in one call. Static
// apps have no unit (Caddy serves them): only their health, tls and backups are checked. If the
// call fails or times out, nothing that depends on it is judged this run (an empty answer is not
// "everything is down").
func (t *tick) findApps() []string {
	names, _ := apps.Names(t.w.Env.Root)
	t.w.Cache.keepApps(t.w.Env.Root, names)
	var withUnit, units []string
	for _, a := range names {
		if !t.w.isStatic(a) {
			withUnit = append(withUnit, a)
			units = append(units, "tando-"+a+".service")
			t.appUnits["tando-"+a+".service"] = true
		}
		// its scheduled jobs: their units, in the same call (keyed by the unit's name)
		t.jobs[a] = t.w.jobsOf(a)
		for _, j := range t.jobs[a] {
			withUnit = append(withUnit, jobUnit(a, j))
			units = append(units, jobUnit(a, j))
		}
		// and its workers' units (keyed by the unit's name)
		t.workers[a] = t.w.workersOf(a)
		for _, n := range t.workers[a] {
			withUnit = append(withUnit, workerUnit(a, n))
			units = append(units, workerUnit(a, n))
		}
	}
	withUnit = append(withUnit, "_caddy")
	units = append(units, "caddy.service")
	if fsinfo.ExistsFollow(filepath.Join(t.w.Units, "tandod.service")) { // (the monitor check: tandod's own unit)
		withUnit = append(withUnit, "_tandod")
		units = append(units, "tandod.service")
	}
	res, err := systemd.Show(t.ctx, t.w.Env.Run, units, unitProps...)
	if err != nil || !answered(res) {
		t.holdAll = true
		t.units["_caddy"] = map[string]string{"ActiveState": "hold"}
		return names
	}
	for i, a := range withUnit {
		t.units[a] = res[i]
	}
	return names
}

func answered(res []map[string]string) bool {
	for _, m := range res {
		if _, ok := m["ActiveState"]; ok {
			return true
		}
	}
	return false
}

// isStatic: the app has no unit (recipe=static: Caddy serves its files).
func (w Watch) isStatic(a string) bool {
	c, _ := w.Cache.load(filepath.Join(w.appDir(a), "app.conf"))
	return c["recipe"] == "static"
}

// loadApp reads one app; nil when nothing is deployed.
func (t *tick) loadApp(a string) *appTick {
	conf, _ := t.w.Cache.load(filepath.Join(t.w.appDir(a), "app.conf"))
	state, _ := t.w.Cache.load(filepath.Join(t.w.appDir(a), "state"))
	if state["current"] == "" {
		return nil
	}
	at := &appTick{name: a, conf: conf, state: state, hold: t.holdAll, down: "hold"}
	at.hasUnit = conf["recipe"] != "static"
	at.stopped = state["stopped"] != "" && state["stopped"] != "0"
	at.unit = t.units[a]
	return at
}

// forgetRemoved drops the state of apps that were removed, and expired silences.
func (t *tick) forgetRemoved() {
	for _, k := range t.st.keys() {
		a, _, _ := strings.Cut(k, ".")
		if !strings.HasPrefix(a, "_") && !fsinfo.DirFollow(t.w.appDir(a)) {
			t.st.del(k)
		}
		if strings.HasPrefix(k, "_sil.") && t.st.n(k, 0) <= t.now {
			t.st.del(k)
		}
	}
	for _, k := range t.vs.keys() {
		p, a, ok := strings.Cut(k, ".")
		if !ok {
			continue
		}
		switch p {
		case "dg", "tls", "oomk", "win", "top", "ema", "sup", "du", "dumb", "pgsz", "pgc", "pgl":
			if !fsinfo.DirFollow(t.w.appDir(a)) {
				t.vs.del(k)
			}
		}
	}
}
