package watch

import (
	"context"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"tando/srv/internal/bashread"
	"tando/srv/internal/decimal"
	"tando/srv/internal/fsinfo"
	"tando/srv/internal/out"
	"tando/srv/internal/systemd"
	"tando/srv/internal/valid"
)

// watchRows is the dead man's check, as rows of type rt for `tando doctor` (check) and `tando
// alerts` (run). It works without root: tandod publishes the time of its last run in its
// status text (`systemctl show -p StatusText tandod`); without a running daemon the last start of
// tando-watch.service or tando-watch-fallback.service counts. The timer is the switch for both:
// stopped, tandod runs no checks of its own either.
func (w Watch) watchRows(ctx context.Context, o *out.Writer, rt string, st *store, now int64) {
	if !fsinfo.ExistsNoFollow(filepath.Join(w.Units, "tando-watch.timer")) {
		o.Row(rt, "warn", "alerts", "not set up: tando alerts enable")
		return
	}
	u := w.watchUnits(ctx)
	timer, d := u[0], u[3]
	// the newest of tandod's last good tick and the last start of the one-shot units (monotonic
	// microseconds since boot against /proc/uptime: no local-time string to parse; date -d fails on
	// zone names such as WIB, with GNU and uutils date alike)
	age, svc := int64(-1), map[string]string(nil)
	var last int64
	for _, s := range u[1:3] {
		if m := num(s["ExecMainStartTimestampMonotonic"], 0); m > last {
			last, svc = m, s
		}
	}
	if last > 0 {
		age = max(w.uptime()-last/1000000, 0)
	}
	if t := daemonLastTick(d); t > 0 && (age < 0 || now-t < age) {
		age, svc = max(now-t, 0), nil
	}
	switch {
	case timer["ActiveState"] != "active":
		o.Row(rt, "fail", "alerts", "tando-watch.timer is "+or(timer["ActiveState"], "missing")+": alerts are not running")
	case age < 0:
		o.Row(rt, "warn", "alerts", "timer active, no run yet")
	case age > 180:
		o.Row(rt, "fail", "alerts", "last check run "+dur(age)+" ago: alerts are not running")
	case svc != nil && or(svc["Result"], "success") != "success":
		o.Row(rt, "fail", "alerts", "last check run failed ("+svc["Result"]+", status "+or(svc["ExecMainStatus"], "?")+"): journalctl -u tando-watch")
	default:
		o.Row(rt, "ok", "alerts", "checks ran "+dur(age)+" ago; "+decimal.Itoa(firingCount(st))+" firing")
	}
}

// watchUnits: the timer, tando-watch.service, tando-watch-fallback.service and tandod.service, as
// systemd sees them (empty maps when it does not answer).
func (w Watch) watchUnits(ctx context.Context) []map[string]string {
	// (two questions: a timer has no service properties; tandod answers both over the bus)
	res := []map[string]string{{}, {}, {}, {}}
	if t, err := systemd.Show(ctx, w.Env.Run, []string{"tando-watch.timer"}, "ActiveState"); err == nil {
		res[0] = t[0]
	}
	if s, err := systemd.Show(ctx, w.Env.Run, []string{"tando-watch.service", "tando-watch-fallback.service", "tandod.service"},
		"ActiveState", "Result", "ExecMainStatus", "ExecMainStartTimestampMonotonic", "StatusText", "MainPID",
		"ActiveEnterTimestampMonotonic"); err == nil {
		copy(res[1:], s)
	}
	return res
}

var lastTickRe = regexp.MustCompile(`last tick ([0-9]+)`)

// daemonLastTick is the epoch of tandod's last run, 0 when it does not run or has not run yet.
func daemonLastTick(d map[string]string) int64 {
	if d["ActiveState"] != "active" && d["ActiveState"] != "reloading" {
		return 0
	}
	if m := lastTickRe.FindStringSubmatch(d["StatusText"]); m != nil {
		return num(m[1], 0)
	}
	return 0
}

// daemonRow is tando doctor's row about tandod, when it is installed: running since, the last
// run, its memory; not running is a warning (the timer runs the checks meanwhile).
func (w Watch) daemonRow(ctx context.Context, o *out.Writer, now int64) {
	if !fsinfo.ExistsNoFollow(filepath.Join(w.Units, "tandod.service")) {
		return
	}
	d := w.watchUnits(ctx)[3]
	if d["ActiveState"] != "active" {
		o.Row("check", "warn", "tandod", "not running ("+or(d["ActiveState"], "unknown")+"): the timer runs the checks; sudo systemctl start tandod")
		return
	}
	v := "running"
	if m := num(d["ActiveEnterTimestampMonotonic"], 0); m > 0 {
		v += " since " + dur(max(w.uptime()-m/1000000, 0)) + " ago"
	}
	if t := daemonLastTick(d); t > 0 {
		v += ", last run " + dur(max(now-t, 0)) + " ago"
	}
	status := "ok"
	if st := d["StatusText"]; strings.Contains(st, "degraded") || strings.Contains(st, "problems:") {
		// panics, runs that failed or died since it started: tando doctor says so
		status = "warn"
		if i := strings.Index(st, "problems:"); i >= 0 {
			v += ", " + st[i:]
		}
		if strings.Contains(st, "degraded") {
			v += "; it handed the checks to the timer (journalctl -u tandod)"
		}
	}
	if pid := d["MainPID"]; decimal.IsDigits(pid) && pid != "0" {
		for l := range strings.SplitSeq(string(readAll(filepath.Join(w.Env.Proc, pid, "status"))), "\n") {
			if kb, ok := strings.CutPrefix(l, "VmRSS:"); ok {
				v += ", " + decimal.Itoa(num(strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(kb), "kB")), 0)/1024) + " MB"
			}
		}
	}
	o.Row("check", status, "tandod", v)
}

func readAll(p string) []byte { b, _ := os.ReadFile(p); return b }

func firingCount(st *store) int64 {
	var n int64
	for k, v := range st.m {
		if strings.HasSuffix(k, ".st") && v == "firing" {
			n++
		}
	}
	return n
}

// Doctor is the verb `doctor`: the dead man's check, and as root the notifiers (a failing one is
// a warning; none at all is said: alerts are then only visible in tando alerts).
func (w Watch) Doctor(ctx context.Context, o *out.Writer) {
	now := w.now()
	st := newStore(loadQuiet(w.statePath()))
	w.watchRows(ctx, o, "check", st, now)
	w.daemonRow(ctx, o, now)
	if desc, stuck := w.stuckHolder(now); stuck { // (root: the record is root's)
		o.Row("check", "fail", "alerts lock", "the lock of the checks is "+desc+": no checks run; sudo kill it")
	}
	if w.Env.EUID != 0 {
		return
	}
	names := w.notifiers()
	for _, n := range names {
		if s := st.get("_nf." + n + ".since"); decimal.IsDigits(s) {
			o.Row("check", "warn", "notifier "+n, "failing for "+dur(now-num(s, 0))+": "+st.or("_nf."+n+".err", "?")+
				"; messages wait in its queue (tando alerts test "+n+")")
		}
	}
	switch {
	case len(names) == 0:
		o.Row("check", "ok", "notifiers", "none: alerts show only in tando alerts")
	case !fsinfo.RegularFollow(filepath.Join(w.Sec, "heartbeat")):
		o.Row("check", "ok", "notifiers", decimal.Itoa(int64(len(names)))+", no heartbeat (tando alerts heartbeat)")
	default:
		o.Row("check", "ok", "notifiers", decimal.Itoa(int64(len(names)))+" and a heartbeat")
	}
}

// Show is the verb `show [n]`: everything `tando alerts` displays, with the last n history lines
// (8 by default).
func (w Watch) Show(ctx context.Context, o *out.Writer, args []string) error {
	if err := needRoot(w.Env); err != nil {
		return err
	}
	now := w.now()
	cfg := loadSettings(w.Conf)
	st := newStore(loadQuiet(w.statePath()))
	vs := newStore(loadQuiet(w.vstatePath()))
	t := &tick{st: st, now: now}
	w.watchRows(ctx, o, "run", st, now)
	if c, err := w.Cache.cksum(w.Self); err == nil {
		o.Row("version", strconv.FormatUint(uint64(c), 10))
	} else {
		o.Row("version", "")
	}
	for _, key := range st.keys() {
		k, isSt := strings.CutSuffix(key, ".st")
		if !isSt || st.get(key) == "ok" {
			continue
		}
		a, c, _ := strings.Cut(k, ".")
		sil := "0"
		if t.silenced(display(a)) {
			sil = "1"
		}
		o.Row("alert", display(a), c, st.get(key), st.get(k+".since"), st.get(k+".det"), st.or(k+".ns", "ok"), sil,
			st.or(k+".flap", "0"), st.get(k+".n"))
	}
	for _, k := range st.keys() {
		if who, ok := strings.CutPrefix(k, "_sil."); ok && st.n(k, 0) > now {
			o.Row("silence", who, st.get(k))
		}
	}
	for _, n := range w.notifiers() {
		nf := loadQuiet(filepath.Join(w.Sec, "notify-"+n))
		var target string
		switch nf["type"] {
		case "telegram":
			c := nf["chat"]
			if len(c) >= 3 {
				c = c[len(c)-3:]
			} else {
				c = "" // (bash ${chat: -3} of a shorter string)
			}
			target = "chat …" + c
		case "email":
			target = nf["to"]
		default:
			target = mask(nf["url"])
		}
		p := "_nf." + n + "."
		o.Row("notifier", n, or(nf["type"], "?"), target, st.get(p+"ok"), st.or(p+"fails", "0"),
			decimal.Itoa(int64(len(w.queuedAll(n)))), st.get(p+"next"), st.get(p+"err"), st.or(p+"dropped", "0"))
	}
	if hbf := filepath.Join(w.Sec, "heartbeat"); fsinfo.RegularFollow(hbf) {
		hb := loadQuiet(hbf)
		o.Row("heartbeat", mask(hb["url"]), vs.get("hb"), st.get("_hb.err"), decimal.Itoa(cfg.num("heartbeat_every", "")))
	}
	n := int64(8)
	if len(args) > 0 {
		n = num(args[0], -1)
	}
	for _, l := range tailLines(w.historyPath(), n) {
		f := bashread.Fields(l, 5)
		o.Row("hist", f[0], f[1], f[2], f[3], f[4])
	}
	for _, d := range defaults {
		v, _ := cfg.raw(d.key, "")
		if !textSetting(d.key) {
			v = decimal.Itoa(cfg.num(d.key, ""))
		}
		o.Row("conf", d.key, v)
	}
	var over []string
	for k := range cfg {
		if strings.Contains(k, ".") {
			over = append(over, k)
		}
	}
	sort.Strings(over)
	for _, k := range over {
		o.Row("conf", k, cfg[k])
	}
	return nil
}

// queuedAll counts every file of a notifier's queue as the shell's glob did (show's QUEUED).
func (w Watch) queuedAll(name string) []string {
	ents, err := os.ReadDir(w.queueDir(name))
	if err != nil {
		return nil
	}
	var res []string
	for _, e := range ents {
		if !strings.HasPrefix(e.Name(), ".") {
			res = append(res, e.Name())
		}
	}
	return res
}

// tailLines is the last n complete lines of a file (tail -n; a negative n is none).
func tailLines(path string, n int64) []string {
	if n <= 0 {
		return nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	ls := bashread.Lines(b)
	if int64(len(ls)) > n {
		ls = ls[int64(len(ls))-n:]
	}
	return ls
}

// History is the verb `history [n]` (50 by default). history.tsv is 600: without root this
// printed nothing and looked like "no alerts yet".
func (w Watch) History(o *out.Writer, args []string) error {
	if err := needRoot(w.Env); err != nil {
		return err
	}
	n := "50"
	if len(args) > 0 {
		n = args[0]
	}
	if !decimal.IsDigits(n) {
		return errf("bad count")
	}
	for _, l := range tailLines(w.historyPath(), num(n, 1<<62)) {
		f := bashread.Fields(l, 5)
		o.Row("hist", f[0], f[1], f[2], f[3], f[4])
	}
	return nil
}

// Brief is the verb `brief [app]`: firing and pending alerts as rows, for `tando status` (no
// root needed: without it the state cannot be read and there are none); for one app also its
// database's size and connections (pgRow).
func (w Watch) Brief(o *out.Writer, args []string) {
	st := newStore(loadQuiet(w.statePath()))
	only := ""
	if len(args) > 0 {
		only = args[0]
	}
	for _, key := range st.keys() {
		k, isSt := strings.CutSuffix(key, ".st")
		if !isSt || st.get(key) == "ok" {
			continue
		}
		a, c, _ := strings.Cut(k, ".")
		if only != "" && display(a) != only {
			continue
		}
		o.Row("alert", display(a), c, st.get(key), st.get(k+".since"), st.get(k+".det"))
	}
	if only != "" && valid.App(only) {
		w.pgRow(o, newStore(loadQuiet(w.vstatePath())), only)
	}
}

// pgRow is what the checks last learned about the app's PostgreSQL database (root: the volatile
// state is root's), for tando status and tando health; nothing for an app without one:
//
//	pg <app> <size in bytes|-> <connections of its role|-> <the role's connection limit|->
func (w Watch) pgRow(o *out.Writer, vs *store, a string) {
	if !vs.has("pgsz."+a) && !vs.has("pgc."+a) {
		return
	}
	o.Row("pg", a, vs.get("pgsz."+a), vs.get("pgc."+a), vs.get("pgl."+a))
}
