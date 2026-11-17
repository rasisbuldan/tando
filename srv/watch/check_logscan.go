package watch

import (
	"os"
	"path/filepath"

	"sort"
	"strings"
	"tando/srv/internal/atomicfile"

	"tando/srv/internal/bashread"
	"tando/srv/internal/decimal"
	"tando/srv/internal/valid"
)

// Errors and requests from the apps' own logs. One call for every app: `tando-logs watch-scan`
// reads each app's journal since its cursor and its request log since its position (both capped
// per run) and prints, per app (its output is the contract between the two programs):
//
//	scan <app> <journal lines read> <error events> <lines journald dropped> <requests> <5xx> <p95 ms> <skipped>
//	top <app> <count> <status> <method path>       up to 3 failing paths
//	release <app> <id> <live since>
//	newerr <app> <id> <first ts> <count> <kind> <label>   an error group seen for the first time
//	errtop <app> <count> <label>                   the top error group of this scan
//
// The rules below keep 5-minute windows in the volatile state:
//
//	http   5xx answers >= http_min and >= http_pct % of requests within 5 minutes
//	slow   p95 latency of real requests over slow_ms for slow_for minutes (>= slow_min requests/min)
//	errors error events >= err_spike within 5 minutes and 5x the usual rate (a slow average)
//	logs   journald dropped lines (rate limit): low severity, resolves after logs_quiet minutes
//
// and an event (sent once) for an error type never seen before that appears within err_new_min
// minutes of a deploy, naming the release. Apps held this run (deploy, down, stopped) are not
// judged. Not run while every app is held (boot).
type scanApp struct {
	nev, sup, tot, e5, p95 int64
	top                    []string
	relID, relT, errTop    string
}

type newErr struct{ app, id, ft, cnt, kind, label, line string }

func checkLogscan(t *tick) {
	if t.holdAll {
		return
	}
	if t.w.Scan == nil {
		return
	}
	out, _ := t.w.Scan.WatchScan(t.ctx)
	out = t.w.keepNewErrors(out)
	sc := map[string]*scanApp{}
	get := func(a string) *scanApp {
		if sc[a] == nil {
			sc[a] = &scanApp{}
		}
		return sc[a]
	}
	var news []newErr
	seen := map[string]bool{} // apps with a scan row
	for _, l := range bashread.Lines(out) {
		f := bashread.Fields(l, 9)
		r, a, x := f[0], f[1], f[2:]
		if !valid.App(a) {
			continue
		}
		switch r {
		case "scan":
			s := get(a)
			seen[a] = true
			n := func(v string) int64 {
				if decimal.IsDigits(v) {
					return num(v, 0)
				}
				return 0
			}
			// (the scan row is split again at spaces: a field with a space shifts the rest, as in the shell)
			w := strings.Fields(strings.Join(x, " "))
			for len(w) < 7 {
				w = append(w, "")
			}
			s.nev, s.sup, s.tot, s.e5, s.p95 = n(w[1]), n(w[2]), n(w[3]), n(w[4]), n(w[5])
		case "top":
			s := get(a)
			s.top = append(s.top, x[0]+"x "+x[1]+" "+clean(x[2]))
		case "release":
			s := get(a)
			s.relID, s.relT = x[0], x[1]
		case "newerr":
			news = append(news, newErr{a, x[0], x[1], x[2], x[3], x[4], a + "\t" + x[0] + "\t" + x[1] + "\t" + x[2] + "\t" + x[3] + "\t" + x[4]})
		case "errtop":
			get(a).errTop = x[0] + "x " + clean(x[1])
		}
	}
	held := map[string]bool{}
	for _, a := range t.apps {
		held[a.name] = a.hold
	}
	names := make([]string, 0, len(seen))
	for a := range seen {
		names = append(names, a)
	}
	sort.Strings(names)
	for _, a := range names {
		t.judgeScan(a, sc[a], held[a])
	}
	t.newErrors(news, sc)
}

// judgeScan applies the rules to one app's scan.
func (t *tick) judgeScan(a string, s *scanApp, held bool) {
	// logs: lines journald dropped (judged even while the app is held: they are gone)
	if t.cfg.on("logs", a) {
		if s.sup > 0 {
			t.st.set(a+".logs_t", decimal.Itoa(t.now))
			t.vs.set("sup."+a, decimal.Itoa(t.vs.n("sup."+a, 0)+s.sup))
		}
		if t.st.get(a+".logs_t") != "" && t.now-t.st.n(a+".logs_t", 0) < t.cfg.num("logs_quiet", a)*60 {
			t.sample(a+".logs", a, "logs", bad, "journald dropped "+t.vs.or("sup."+a, decimal.Itoa(s.sup))+
				" log lines: the app logs faster than its log_rate (tando.conf); tando logs -a "+a+" shows a note where", 1)
		} else {
			t.sample(a+".logs", a, "logs", ok, "", 1)
			t.st.del(a + ".logs_t")
			t.vs.del("sup." + a)
		}
	}
	// rolling 5-minute windows: "time:requests:5xx:errors,..."
	var win []string
	for _, x := range splitList(t.vs.get("win." + a)) {
		ts, _, _ := strings.Cut(x, ":")
		if decimal.IsDigits(ts) && t.now-num(ts, 0) < 290 {
			win = append(win, x)
		}
	}
	win = append(win, decimal.Itoa(t.now)+":"+decimal.Itoa(s.tot)+":"+decimal.Itoa(s.e5)+":"+decimal.Itoa(s.nev))
	t.vs.set("win."+a, strings.Join(win, ","))
	var sum5, sumt, m int64
	for _, x := range win {
		p := strings.SplitN(x, ":", 4)
		for len(p) < 4 {
			p = append(p, "")
		}
		sumt += num(p[1], 0)
		sum5 += num(p[2], 0)
		m += num(p[3], 0)
	}
	if len(s.top) > 0 {
		t.vs.set("top."+a, strings.Join(s.top, ", "))
	}
	if held {
		return // (held: http, slow and errors are left alone)
	}
	// http: 5xx answers to real requests
	if t.cfg.on("http", a) {
		need, pct := t.cfg.num("http_min", a), t.cfg.num("http_pct", a)
		if sum5 >= need && sum5*100 >= pct*sumt && sumt > 0 {
			t.sample(a+".http", a, "http", bad, decimal.Itoa(sum5)+" of "+decimal.Itoa(sumt)+" requests answered 5xx ("+
				decimal.Itoa(sum5*100/sumt)+"%) in 5 min; top: "+t.vs.or("top."+a, "?"), 1)
		} else {
			t.sample(a+".http", a, "http", ok, "", 1)
		}
	}
	// slow: p95 latency of the minute
	if t.cfg.on("slow", a) {
		need, ms, n := t.cfg.num("slow_min", a), t.cfg.num("slow_ms", a), t.cfg.num("slow_for", a)
		switch {
		case s.tot < need:
		case s.p95 > ms:
			t.sample(a+".slow", a, "slow", bad, "p95 latency "+decimal.Itoa(s.p95)+" ms of "+decimal.Itoa(s.tot)+
				" requests in the last minute (over slow_ms "+decimal.Itoa(ms)+")", n)
		default:
			t.sample(a+".slow", a, "slow", ok, "", n)
		}
	}
	// errors: a spike of error events in the app's log against its usual rate (per mille/min)
	if t.cfg.on("errors", a) {
		ema := t.vs.n("ema."+a, 0)
		if !decimal.IsDigits(t.vs.get("ema." + a)) {
			ema = 0
		}
		sp := t.cfg.num("err_spike", a)
		if m >= sp && m*1000 >= 25*ema { // 5 minutes x 5 x the per-minute average
			t.sample(a+".errors", a, "errors", bad, decimal.Itoa(m)+" error events in the app log in 5 min (usually about "+
				decimal.Itoa((ema*5+500)/1000)+"); most: "+or(s.errTop, "?")+"; tando errors -a "+a, 1)
		} else {
			t.sample(a+".errors", a, "errors", ok, "", 1)
		}
		t.vs.set("ema."+a, decimal.Itoa(ema+(s.nev*1000-ema)/60))
	}
}

// newErrors: new error types shortly after a deploy, one event each, oldest first, at most 3 per
// app and run (then one "and N more").
func (t *tick) newErrors(news []newErr, sc map[string]*scanApp) {
	win := t.cfg.num("err_new_min", "")
	sort.Slice(news, func(i, j int) bool {
		a, b := news[i], news[j]
		if fa, fb := num(a.ft, 0), num(b.ft, 0); fa != fb {
			return fa < fb
		}
		if a.id != b.id {
			return a.id < b.id
		}
		return a.line < b.line
	})
	nn := map[string]int64{}
	var order []string
	for _, e := range news {
		s := sc[e.app]
		if !t.cfg.on("errors", e.app) || s == nil || !decimal.IsDigits(s.relT) || !decimal.IsDigits(e.ft) {
			continue
		}
		since := num(e.ft, 0) - num(s.relT, 0)
		if since < -60 || since > win*60 {
			continue
		}
		if nn[e.app] == 0 {
			order = append(order, e.app)
		}
		nn[e.app]++
		if nn[e.app] > 3 {
			continue
		}
		lab := e.label
		if e.kind == "line" {
			lab = "an error line"
		}
		t.event("newerror", e.app, "errors", "new error after release "+s.relID+" (live "+dur(max(since, 0))+
			" when it first appeared): "+clean(lab)+", "+e.cnt+"x ["+e.id+"]; tando errors -a "+e.app+
			"; to undo the release: tando rollback -a "+e.app)
	}
	sort.Strings(order)
	for _, a := range order {
		if nn[a] > 3 {
			t.event("newerror", a, "errors", "and "+decimal.Itoa(nn[a]-3)+" more new error types after release "+sc[a].relID+": tando errors -a "+a)
		}
	}
}

// The scan remembers an error group the moment it reads it, before this run commits. A run that
// dies after the scan (a panic in a later check, its deadline, a kill) would lose that group's
// "new error" message for good: the next scan knows the group already. So the newerr rows are
// kept in a file from the scan until the commit, and a run that finds the file judges its rows
// again with its own. (A kill between the commit and the removal sends them twice: once too
// often, never not at all. The request counts of the lost minute are not kept.)
const newErrPendingMax = 64 << 10

func (w Watch) newErrPendingPath() string {
	return filepath.Join(filepath.Dir(w.statePath()), "newerr.pending")
}

// keepNewErrors returns the scan's output with the kept rows of earlier runs in front, and keeps
// this scan's newerr rows with them.
func (w Watch) keepNewErrors(out []byte) []byte {
	p := w.newErrPendingPath()
	var kept []byte
	if fi, err := os.Lstat(p); err == nil && fi.Mode().IsRegular() && fi.Size() <= newErrPendingMax {
		kept, _ = os.ReadFile(p)
	}
	var b strings.Builder
	for _, l := range bashread.Lines(kept) {
		if strings.HasPrefix(l, "newerr\t") {
			b.WriteString(l + "\n")
		}
	}
	prior := b.Len()
	for _, l := range bashread.Lines(out) {
		if strings.HasPrefix(l, "newerr\t") && b.Len()+len(l) < newErrPendingMax {
			b.WriteString(l + "\n")
		}
	}
	if b.Len() == 0 {
		return out
	}
	if b.Len() != len(kept) {
		atomicfile.Write(p, []byte(b.String()), atomicfile.Mode(0o600))
	}
	return append([]byte(b.String()[:prior]), out...)
}

// newErrorsCommitted: the run that judged the kept rows has committed.
func (w Watch) newErrorsCommitted() { os.Remove(w.newErrPendingPath()) }
