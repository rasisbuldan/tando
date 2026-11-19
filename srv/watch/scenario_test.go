package watch

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"tando/srv/internal/decimal"
	"tando/srv/internal/out"
)

// countSent: notifications so far whose body contains s.
func (f *fakeHost) countSent(s string) int {
	n := 0
	for _, b := range f.sentBodies() {
		n += strings.Count(b, s)
	}
	return n
}

func hostWithHog(t *testing.T) *fakeHost {
	f := newFakeHost(t)
	f.app("hog")
	f.notifier("hook", "type=webhook\nurl=http://127.0.0.1:9/hook/S3CR3T\n")
	f.ticks(2)
	f.reset()
	return f
}

func TestHealthFiresAfterFailsAndResolvesAfterRecover(t *testing.T) {
	for _, tt := range []struct {
		name         string
		conf         []string
		settings     []string
		fails, recov int
	}{
		{"defaults: 3 to fire, 2 to resolve", nil, nil, 3, 2},
		{"tando.conf health_fails=2 health_recover=3", []string{"health_fails=2", "health_recover=3"}, nil, 2, 3},
		{"alerts set health_fails=08 (decimal, not octal)", nil, []string{"health_fails=08", "resolve_after=1"}, 8, 1},
	} {
		t.Run(tt.name, func(t *testing.T) {
			f := newFakeHost(t)
			f.app("hog", tt.conf...)
			f.notifier("hook", "type=webhook\nurl=http://127.0.0.1:9/hook\n")
			f.settings(append([]string{"liveness=0"}, tt.settings...)...)
			f.ticks(2)
			f.reset()
			f.probe["http://hog.localhost/health"] = probeRes{code: 500, body: "sick"}
			f.ticks(tt.fails - 1)
			if st := f.st("hog.health.st"); st != "pending" || len(f.sentBodies()) != 0 {
				t.Fatalf("after %d bad probes: state %q, %d sent; want pending, 0", tt.fails-1, st, len(f.sentBodies()))
			}
			f.tick()
			if f.st("hog.health.st") != "firing" || f.countSent(`"state":"firing","app":"hog","check":"health"`) != 1 {
				t.Fatalf("not fired once: %q %v", f.st("hog.health.st"), f.sentBodies())
			}
			if d := f.st("hog.health.det"); !strings.HasPrefix(d, "unhealthy: answered HTTP 500, expected 2xx/3xx; hog.localhost/health (") {
				t.Errorf("detail %q", d)
			}
			f.ticks(3)
			if len(f.sentBodies()) != 1 {
				t.Errorf("repeated while firing: %d", len(f.sentBodies()))
			}
			delete(f.probe, "http://hog.localhost/health")
			f.ticks(tt.recov - 1)
			if f.st("hog.health.st") != "firing" {
				t.Fatalf("resolved too early")
			}
			f.tick()
			// (the state stays "ok" while its firing time is within flap_window)
			if f.st("hog.health.st") != "ok" || f.countSent(`"state":"resolved","app":"hog","check":"health"`) != 1 {
				t.Fatalf("not resolved once: %q %v", f.st("hog.health.st"), f.sentBodies())
			}
		})
	}
}

func TestTransientFailureSendsNothing(t *testing.T) {
	f := hostWithHog(t)
	f.probe["http://hog.localhost/health"] = probeRes{code: 500}
	f.tick()
	delete(f.probe, "http://hog.localhost/health")
	f.ticks(3)
	if n := len(f.sentBodies()); n != 0 || f.st("hog.health.st") != "" {
		t.Errorf("%d sent, state %q", n, f.st("hog.health.st"))
	}
	// bad samples more than 5 minutes apart do not add up
	f.probe["http://hog.localhost/health"] = probeRes{code: 500}
	f.ticks(2)
	f.now = f.now.Add(10 * time.Minute)
	f.tick()
	if f.st("hog.health.st") != "pending" || f.st("hog.health.n") != "1" {
		t.Errorf("after a gap: %q n=%q", f.st("hog.health.st"), f.st("hog.health.n"))
	}
}

func TestHealthClasses(t *testing.T) {
	for _, tt := range []struct {
		expect string
		res    probeRes
		det    string
	}{
		{"", probeRes{exit: 28, code: 0}, "slow: no answer within 10 s (health_timeout)"},
		{"", probeRes{code: 503, body: "hog is busy: too many"}, "saturated: Caddy answered 503 busy"},
		{"", probeRes{code: 503, body: "hog is unavailable"}, "down: Caddy answered 503, no process"},
		{"", probeRes{code: 503}, "unhealthy: answered HTTP 503;"},
		{"", probeRes{code: 502}, "unhealthy: Caddy got no answer from the app's port (HTTP 502)"},
		{"200 ok", probeRes{code: 200, body: "nope"}, `unhealthy: answered HTTP 200 without "ok"`},
		{"2xx", probeRes{code: 301}, "unhealthy: answered HTTP 301, expected 2xx"},
		{"", probeRes{exit: 7}, "unhealthy: connection refused"},
		{"", probeRes{exit: 52}, "unhealthy: empty reply"},
		{"", probeRes{exit: 35}, "unhealthy: probe failed (curl error 35)"},
	} {
		f := newFakeHost(t)
		f.app("hog", "health_expect="+tt.expect, "health_fails=1")
		f.settings("liveness=0")
		f.probe["http://hog.localhost/health"] = tt.res
		f.tick()
		if d := f.st("hog.health.det"); !strings.Contains(d, tt.det) {
			t.Errorf("%+v: detail %q, want %q", tt.res, d, tt.det)
		}
	}
	// a 200 with the expected text, and "Nxx"
	f := newFakeHost(t)
	f.app("hog", "health_expect=2xx ok", "health_fails=1")
	f.probe["http://hog.localhost/health"] = probeRes{code: 204, body: "all ok"}
	f.tick()
	if f.st("hog.health.st") != "" {
		t.Errorf("2xx ok with text: %q", f.st("hog.health.st"))
	}
}

// An adopted app sits behind a hand-written Caddy site: it is probed at that site's address,
// not at <app>.<apps_domain>, which no site answers.
func TestAdoptedAppIsProbedAtItsOwnSite(t *testing.T) {
	f := newFakeHost(t)
	f.app("shop", "check_url=https://example.net", "path=/shop", "health_fails=1")
	f.settings("liveness=0")
	f.probe["http://shop.localhost/shop/health"] = probeRes{exit: 35}
	f.tick()
	if st := f.st("shop.health.st"); st != "" {
		t.Errorf("probed the default link: %q %q", st, f.st("shop.health.det"))
	}
	f.probe["https://example.net/shop/health"] = probeRes{code: 502}
	f.tick()
	if d := f.st("shop.health.det"); !strings.Contains(d, "example.net/shop/health") {
		t.Errorf("detail %q", d)
	}
}

func TestFlapping(t *testing.T) {
	f := hostWithHog(t)
	f.settings("hog.health_fails=1", "hog.resolve_after=1", "liveness=0")
	for range 4 {
		f.probe["http://hog.localhost/health"] = probeRes{code: 500}
		f.tick()
		delete(f.probe, "http://hog.localhost/health")
		f.tick()
	}
	h := f.history()
	got := []int{f.count(h, "fire hog health"), f.count(h, "resolve hog health"), f.count(h, "flap hog health"), len(f.sentBodies())}
	// sent: 2 firings, 2 resolves, then the flapping notice; then nothing
	if got[2] != 1 || len(f.sentBodies()) != 5 || f.countSent(`"state":"flap"`) != 1 {
		t.Errorf("fire/resolve/flap/messages = %v; bodies %v", got, f.sentBodies())
	}
	// stable for flap_window: the current state is sent if it differs from the last sent
	f.now = f.now.Add(61 * time.Minute)
	f.tick()
	if f.st("hog.health.flap") == "1" {
		t.Errorf("still flapping after the window")
	}
}

func TestSilence(t *testing.T) {
	f := hostWithHog(t)
	w := f.watch()
	silence := func(a ...string) error {
		_, err := do(func(o *out.Writer) error { return w.Silence(o, a) })
		return err
	}
	if o, err := do(func(o *out.Writer) error { return w.Silence(o, []string{"hog", "600"}) }); err != nil ||
		o != "until="+decimal.Itoa(f.now.Unix()+600)+"\n" {
		t.Fatalf("silence: %v %q", err, o)
	}
	f.probe["http://hog.localhost/health"] = probeRes{code: 500}
	f.ticks(3)
	if f.st("hog.health.st") != "firing" || len(f.sentBodies()) != 0 {
		t.Fatalf("silenced: %q, %d sent", f.st("hog.health.st"), len(f.sentBodies()))
	}
	silence("hog", "0")
	f.tick()
	if f.countSent(`"state":"firing"`) != 1 {
		t.Fatalf("lifted while firing: %v", f.sentBodies())
	}
	// fired and resolved inside a silence: nothing owed afterwards
	f.reset()
	delete(f.probe, "http://hog.localhost/health")
	f.ticks(2)
	f.reset()
	silence("all", "300")
	f.probe["http://hog.localhost/health"] = probeRes{code: 500}
	f.ticks(3)
	delete(f.probe, "http://hog.localhost/health")
	f.ticks(2)
	silence("all", "0")
	f.ticks(2)
	if n := len(f.sentBodies()); n != 0 {
		t.Errorf("owed after a silence: %v", f.sentBodies())
	}
	if err := silence("hog", "08"); err != nil {
		t.Errorf("silence 08 (decimal): %v", err)
	}
}

func TestReminderAndTurnedOff(t *testing.T) {
	f := hostWithHog(t)
	f.settings("disk_pct=0", "liveness=0")
	f.tick()
	if f.countSent(`"state":"firing","app":"host","check":"disk"`) != 1 {
		t.Fatalf("host disk did not fire: %v", f.sentBodies())
	}
	f.now = f.now.Add(6 * time.Hour)
	f.ticks(2)
	if n := f.countSent(`"state":"still firing","app":"host","check":"disk"`); n != 1 {
		t.Errorf("reminders: %d", n)
	}
	f.settings("disk_pct=0", "disk=off", "liveness=0")
	f.tick()
	if f.countSent(`"state":"resolved","app":"host","check":"disk","detail":"the check was turned off"`) != 1 {
		t.Errorf("turned off: %v", f.sentBodies())
	}
}

func TestBackoffAndQueue(t *testing.T) {
	f := hostWithHog(t)
	f.code = 500
	f.probe["http://hog.localhost/health"] = probeRes{code: 500}
	f.settings("liveness=0")
	f.ticks(3)
	t0 := f.now.Add(-time.Minute).Unix()
	st := f.state()
	if st["_nf.hook.fails"] != "1" || st["_nf.hook.err"] != "HTTP 500" || st["_nf.hook.next"] != decimal.Itoa(t0+55) || st["_nf.hook.since"] != decimal.Itoa(t0) {
		t.Fatalf("after one failure: %v", st)
	}
	if len(f.queueFiles("hook")) != 1 {
		t.Fatalf("queue: %v", f.queueFiles("hook"))
	}
	f.tick() // 60 s later: retried, fails again: 2 min
	if st := f.state(); st["_nf.hook.fails"] != "2" || st["_nf.hook.next"] != decimal.Itoa(t0+60+115) {
		t.Fatalf("second failure: %v", st)
	}
	n := len(f.sentBodies())
	f.tick() // in backoff: not tried
	if len(f.sentBodies()) != n {
		t.Errorf("tried during backoff")
	}
	delete(f.probe, "http://hog.localhost/health")
	f.ticks(2) // resolves: queued too
	f.code = 200
	f.now = f.now.Add(5 * time.Minute)
	f.tick()
	last := f.sentBodies()[len(f.sentBodies())-1]
	if !strings.Contains(last, `"state":"firing","app":"hog"`) || !strings.Contains(last, `"state":"resolved","app":"hog"`) {
		t.Errorf("not one combined delivery: %s", last)
	}
	if st := f.state(); st["_nf.hook.fails"] != "" || st["_nf.hook.ok"] == "" || len(f.queueFiles("hook")) != 0 {
		t.Errorf("after recovery: %v %v", st, f.queueFiles("hook"))
	}
	for _, b := range []int64{1, 2, 3, 6, 7, 20} {
		want := map[int64]int64{1: 60, 2: 120, 3: 240, 6: 1920, 7: 3600, 20: 3600}[b]
		if got := backoff(b); got != want {
			t.Errorf("backoff(%d) = %d, want %d", b, got, want)
		}
	}
}

func TestQueueBound(t *testing.T) {
	f := hostWithHog(t)
	w := f.watch()
	st := newStore(nil)
	for i := range 105 {
		w.enqueue("hook", decimal.Itoa(int64(1000+i))+".1", []byte("firing\thog\thealth\tx\t1\n"), st)
	}
	q := f.queueFiles("hook")
	if len(q) != 100 || !strings.HasSuffix(q[0], "/1005.1") || st.get("_nf.hook.dropped") != "5" {
		t.Errorf("%d queued, first %s, dropped %q", len(q), q[0], st.get("_nf.hook.dropped"))
	}
}

func TestLivenessCap(t *testing.T) {
	f := hostWithHog(t)
	f.probe["http://hog.localhost/health"] = probeRes{exit: 28}
	f.ticks(20) // a restart every 3 failed probes, at most 3 within the hour
	restarts := f.called("systemd-run")
	if len(restarts) != 3 {
		t.Fatalf("%d restarts in 20 min, want 3", len(restarts))
	}
	h := f.history()
	if f.count(h, "restart hog health") != 4 { // 3 restarts and the "stops now"
		t.Errorf("history: %v", h)
	}
	if !strings.Contains(strings.Join(restarts[0], " "), "tando-agent restart hog") {
		t.Errorf("restart argv %v", restarts[0])
	}
	f.now = f.now.Add(61 * time.Minute)
	f.ticks(3)
	if len(f.called("systemd-run")) != 4 {
		t.Errorf("not restarted again after the hour")
	}
	// a saturated app answers on its own port: not restarted
	g := hostWithHog(t)
	g.direct = 200
	g.probe["http://hog.localhost/health"] = probeRes{exit: 28}
	g.ticks(6)
	if len(g.called("systemd-run")) != 0 {
		t.Errorf("restarted an app that answers on its port")
	}
	// liveness=0: never
	h0 := hostWithHog(t)
	h0.settings("liveness=0")
	h0.probe["http://hog.localhost/health"] = probeRes{exit: 28}
	h0.ticks(6)
	if len(h0.called("systemd-run")) != 0 {
		t.Errorf("liveness=0 restarted")
	}
}

func TestDiskGuard(t *testing.T) {
	for _, tt := range []struct {
		du       string
		settings []string
		fire     bool
		stopped  bool
	}{
		{"100", nil, false, false},
		{"9000", []string{"disk_stop_pct=0"}, true, false},
		{"9000", []string{"disk_stop_pct=1"}, true, true}, // (the temp file system is at least 1% full)
		{"9000", []string{"disk_stop_pct=100"}, true, false},
	} {
		f := hostWithHog(t)
		f.du = tt.du
		f.settings(append([]string{"disk_every=0"}, tt.settings...)...)
		f.tick()
		fired := f.st("hog.disk.st") == "firing"
		stopped := len(f.called("systemd-run")) == 1 && strings.Contains(strings.Join(f.called("systemd-run")[0], " "), f.path("opt/bin/tando-agent")+" stop hog")
		if fired != tt.fire || stopped != tt.stopped {
			t.Errorf("du %s %v: fired %v stopped %v; detail %q", tt.du, tt.settings, fired, stopped, f.st("hog.disk.det"))
		}
		if tt.fire && !strings.HasPrefix(f.st("hog.disk.det"), "hog uses 9000 MB of disk, over the 8192 MB allowed per app") {
			t.Errorf("detail %q", f.st("hog.disk.det"))
		}
		if f.vstate()["dumb.hog"] != tt.du {
			t.Errorf("dumb.hog = %q", f.vstate()["dumb.hog"])
		}
	}
}

func TestLogscanThresholds(t *testing.T) {
	logs := func(f *fakeHost) {
		f.write("opt/bin/tando-logs", "#!fake\n")
		os.Chmod(f.path("opt/bin/tando-logs"), 0o755)
	}
	// http: >= http_min 5xx and >= http_pct of the requests within 5 minutes
	for _, tt := range []struct {
		scan string
		fire bool
	}{
		{"scan\thog\t10\t0\t0\t20\t8\t50\t0\ntop\thog\t8\t500\tGET /api/fail/:n\n", true},
		{"scan\thog\t10\t0\t0\t100\t4\t50\t0\n", false},   // fewer than http_min
		{"scan\thog\t10\t0\t0\t1000\t50\t50\t0\n", false}, // 5%
	} {
		f := hostWithHog(t)
		logs(f)
		f.scan = tt.scan
		f.tick()
		if fired := f.st("hog.http.st") == "firing"; fired != tt.fire {
			t.Errorf("http %q: fired %v (%q)", tt.scan, fired, f.st("hog.http.det"))
		}
		if tt.fire && f.st("hog.http.det") != "8 of 20 requests answered 5xx (40%) in 5 min; top: 8x 500 GET /api/fail/:n" {
			t.Errorf("http detail %q", f.st("hog.http.det"))
		}
	}
	// slow: p95 over slow_ms for slow_for minutes with at least slow_min requests
	f := hostWithHog(t)
	logs(f)
	f.scan = "scan\thog\t10\t0\t0\t50\t0\t4000\t0\n"
	f.ticks(4)
	if f.st("hog.slow.st") != "pending" {
		t.Errorf("slow after 4: %q", f.st("hog.slow.st"))
	}
	f.scan = "scan\thog\t10\t0\t0\t5\t0\t4000\t0\n" // too few requests: not judged
	f.tick()
	f.scan = "scan\thog\t10\t0\t0\t50\t0\t4000\t0\n"
	f.tick()
	if f.st("hog.slow.st") != "firing" {
		t.Errorf("slow after 5 judged minutes: %q", f.st("hog.slow.st"))
	}
	// errors: a spike against the usual rate
	g := hostWithHog(t)
	logs(g)
	g.scan = "scan\thog\t10\t25\t0\t0\t0\t0\t0\nerrtop\thog\t25\tTypeError at x (server.js)\n"
	g.tick()
	if g.st("hog.errors.det") != "25 error events in the app log in 5 min (usually about 0); most: 25x TypeError at x (server.js); tando errors -a hog" {
		t.Errorf("errors: %q %q", g.st("hog.errors.st"), g.st("hog.errors.det"))
	}
	g2 := hostWithHog(t)
	logs(g2)
	g2.scan = "scan\thog\t10\t19\t0\t0\t0\t0\t0\n"
	g2.tick()
	if g2.st("hog.errors.st") != "" {
		t.Errorf("19 errors fired")
	}
	// logs: lines journald dropped, low severity
	h := hostWithHog(t)
	logs(h)
	h.scan = "scan\thog\t10\t0\t30\t0\t0\t0\t0\n"
	h.tick()
	if h.st("hog.logs.st") != "firing" || h.countSent("FIRING hog/logs (low): journald dropped 30 log lines") != 1 {
		t.Errorf("logs: %q %v", h.st("hog.logs.st"), h.sentBodies())
	}
}

func TestNewErrorsAfterRelease(t *testing.T) {
	f := hostWithHog(t)
	f.write("opt/bin/tando-logs", "#!fake\n")
	os.Chmod(f.path("opt/bin/tando-logs"), 0o755)
	now := f.now.Unix()
	rel := now - 120
	var b strings.Builder
	b.WriteString("scan\thog\t10\t5\t0\t0\t0\t0\t0\nrelease\thog\t20261115-013512\t" + decimal.Itoa(rel) + "\n")
	for i, id := range []string{"aa", "bb", "cc", "dd", "ee"} {
		b.WriteString("newerr\thog\t" + id + "\t" + decimal.Itoa(now-int64(10*(5-i))) + "\t2\ttrace\tTypeError at f" + id + " (server.js)\n")
	}
	b.WriteString("newerr\thog\tzz\t" + decimal.Itoa(rel-3600) + "\t1\tline\tsecret text\n") // before the release
	f.scan = b.String()
	f.tick()
	if n := f.countSent("NEW ERROR hog: new error after release 20261115-013512 (live"); n != 3 {
		t.Errorf("%d notices, want 3: %v", n, f.sentBodies())
	}
	if f.countSent("NEW ERROR hog: and 2 more new error types after release 20261115-013512") != 1 ||
		f.countSent("NEW ERROR hog: new error after release 20261115-013512 (live 1m 10s when it first appeared): TypeError at faa (server.js), 2x [aa]; tando errors -a hog; to undo the release: tando rollback -a hog") != 1 ||
		f.countSent("secret") != 0 {
		t.Errorf("bodies: %v", f.sentBodies())
	}
}

func TestDownAndCaddyHoldHealth(t *testing.T) {
	f := hostWithHog(t)
	f.unit("tando-hog.service", "activating", "auto-restart", "5")
	f.units["tando-hog.service"]["Result"] = "exit-code"
	f.journal["process exited, code="] = "tando-hog.service: Main process exited, code=exited, status=3/NOTIMPLEMENTED\n"
	f.probe["http://hog.localhost/health"] = probeRes{code: 502}
	f.tick()
	if f.st("hog.down.st") != "pending" || f.st("hog.health.st") != "" {
		t.Fatalf("down %q health %q", f.st("hog.down.st"), f.st("hog.health.st"))
	}
	f.tick()
	if f.st("hog.down.st") != "firing" || f.st("hog.down.det") != "crash-looping (restarting; last result: exit-code, exit status 3)" {
		t.Errorf("down %q %q", f.st("hog.down.st"), f.st("hog.down.det"))
	}
	g := hostWithHog(t)
	g.unit("caddy.service", "failed", "failed", "0")
	g.probe["http://hog.localhost/health"] = probeRes{code: 502}
	g.ticks(4)
	if g.st("_host.caddy.st") != "firing" || g.st("hog.health.st") != "" || g.countSent("FIRING host/caddy") != 1 {
		t.Errorf("caddy %q hog health %q; %v", g.st("_host.caddy.st"), g.st("hog.health.st"), g.sentBodies())
	}
	// a stopped app is not an outage
	s := hostWithHog(t)
	s.write("opt/apps/hog/state", "current=20261114-170102\nphase=idle\nstopped=1\n")
	s.unit("tando-hog.service", "inactive", "dead", "0")
	s.ticks(3)
	if s.st("hog.down.st") != "" || len(s.sentBodies()) != 0 {
		t.Errorf("stopped app: %q", s.st("hog.down.st"))
	}
}

func TestRebootAndBootGrace(t *testing.T) {
	f := hostWithHog(t)
	f.boot = f.now.Unix() - 30 // started 30 s ago: boot_grace holds the apps for 3 runs
	f.probe["http://hog.localhost/health"] = probeRes{code: 500}
	f.ticks(3)
	h := f.history()
	if f.count(h, "reboot host reboot") != 1 || f.st("hog.health.st") != "" || f.countSent("RESTARTED host: the host restarted") != 1 {
		t.Errorf("history %v, health %q", h, f.st("hog.health.st"))
	}
	f.tick()
	if f.st("hog.health.st") != "pending" {
		t.Errorf("after boot_grace: %q", f.st("hog.health.st"))
	}
}

func TestInbox(t *testing.T) {
	f := hostWithHog(t)
	now := f.now.Unix()
	f.write("lib/watch/inbox/"+decimal.Itoa(now)+".hog.20261115-013512", "rollback\thog\t20261115-013512\trelease 20261115-013512 rolled back to x: health\n")
	f.write("lib/watch/inbox/"+decimal.Itoa(now-7200)+".hog.old", "rollback\thog\told\tstale\n")
	f.ticks(2)
	if f.countSent("ROLLED BACK hog: release 20261115-013512 rolled back to x: health") != 1 || f.countSent("stale") != 0 {
		t.Errorf("%v", f.sentBodies())
	}
	if m, _ := os.ReadDir(f.path("lib/watch/inbox")); len(m) != 0 {
		t.Errorf("inbox not empty: %v", m)
	}
}

// A run killed after its commit point is finished by the next run; one killed before it is
// decided again. Either way every message is queued exactly once.
func TestCommitRecovery(t *testing.T) {
	f := hostWithHog(t)
	w := f.watch()
	now := f.now.Unix()
	c := commitLog{id: decimal.Itoa(now) + ",77", events: []event{{"fire", "hog", "health", "x"}},
		msgs: []string{"firing\thog\thealth\tx\t" + decimal.Itoa(now) + "\n"}}
	os.WriteFile(w.commitPath(), c.encode(), 0o600)
	st := loadState(w.statePath())
	st.set("_out", c.id)
	st.save(w.statePath())
	f.code = 500 // keep it queued
	f.tick()
	q := f.queueFiles("hook")
	if len(q) != 1 || !strings.HasSuffix(q[0], "/"+decimal.Itoa(now)+".77") || f.count(f.history(), "fire hog health") != 1 {
		t.Fatalf("committed: queue %v history %v", q, f.history())
	}
	if _, err := os.Stat(w.commitPath()); err == nil {
		t.Errorf("commit file left")
	}
	// not committed (state without its id): dropped
	c.id = decimal.Itoa(now) + ",78"
	os.WriteFile(w.commitPath(), c.encode(), 0o600)
	f.tick()
	if q2 := f.queueFiles("hook"); len(q2) != 1 {
		t.Errorf("uncommitted effects applied: %v", q2)
	}
	// applying twice gives the same queue file
	g := hostWithHog(t)
	g.code = 500
	gw := g.watch()
	st2 := newStore(nil)
	gw.apply(commitLog{id: "100,1", msgs: []string{"firing\thog\thealth\tx\t100\n"}}, st2)
	os.WriteFile(gw.commitPath(), []byte("x"), 0o600)
	gw.apply(commitLog{id: "100,1", msgs: []string{"firing\thog\thealth\tx\t100\n"}}, st2)
	if q := g.queueFiles("hook"); len(q) != 1 {
		t.Errorf("twice: %v", q)
	}
}

func TestNotifierPayloads(t *testing.T) {
	f := newFakeHost(t)
	w := f.watch()
	f.write("q/1", "firing\thog\thealth\tunhealthy: \"x\"\\y\t1800000000\nresolved\thost\tdisk\tafter 2m 0s (was: disk / is 91% full)\t1800000060\n"+
		"firing\tboom\tlogs\tjournald dropped 3 log lines\t1800000000\n")
	m := w.compose(loadSettings(f.path("none")), []string{f.path("q/1")})
	ev := `[{"state":"firing","app":"hog","check":"health","detail":"unhealthy: \"x\"\\y","since":1800000000},` +
		`{"state":"resolved","app":"host","check":"disk","detail":"after 2m 0s (was: disk / is 91% full)","since":1800000060},` +
		`{"state":"firing","app":"boom","check":"logs","detail":"journald dropped 3 log lines","since":1800000000}]`
	title := "tando testhost: 2 firing, 1 resolved"
	text := title + "\nFIRING hog/health: unhealthy: \"x\"\\y\nRESOLVED host/disk: after 2m 0s (was: disk / is 91% full)\n" +
		"FIRING boom/logs (low): journald dropped 3 log lines"
	if m.title != title || m.text != text || m.events != ev || !m.hipri {
		t.Fatalf("composed %+v", m)
	}
	jt := jsonString(text)
	for _, tt := range []struct {
		conf, url, body string
		header          []string
	}{
		{"type=webhook\nurl=http://h/hook/S\n", "http://h/hook/S",
			`{"host":"testhost","title":"` + title + `","text":` + jt + `,"events":` + ev + `}`, []string{"Content-Type: application/json"}},
		{"type=slack\nurl=http://h/slack/S\n", "http://h/slack/S", `{"text":` + jt + `}`, []string{"Content-Type: application/json"}},
		{"type=telegram\ntoken=S:abc\nchat=-100123\napi=http://h/tg\n", "http://h/tg/botS:abc/sendMessage",
			`{"chat_id":"-100123","text":` + jt + `,"disable_web_page_preview":true}`, []string{"Content-Type: application/json"}},
		{"type=ntfy\nurl=http://h/ntfy/S\ntoken=tok\n", "http://h/ntfy/S", strings.SplitN(text, "\n", 2)[1],
			[]string{"Title: " + title, "Priority: high", "Authorization: Bearer tok"}},
	} {
		f.reset()
		f.notifier("n", tt.conf)
		r, err := w.notifier("n").Send(context.Background(), m)
		if err != nil || r != "HTTP 200" {
			t.Errorf("%s: %q %v", tt.conf, r, err)
		}
		s := f.sends[0]
		if s.url != tt.url || s.body != tt.body {
			t.Errorf("%s:\n url  %s\n body %s\nwant %s\n body %s", tt.conf, s.url, s.body, tt.url, tt.body)
		}
		hs := map[string]bool{}
		for _, h := range s.header {
			hs[h[0]+": "+h[1]] = true
		}
		for _, h := range tt.header {
			if !hs[h] {
				t.Errorf("%s: header %q missing in %v", tt.conf, h, s.header)
			}
		}
	}
	f.code = 500
	f.notifier("n", "type=webhook\nurl=http://h/x\n")
	if _, err := w.notifier("n").Send(context.Background(), m); err == nil || errText(err) != "HTTP 500" {
		t.Errorf("500: %v", err)
	}
	f.notifier("n", "type=other\n")
	if _, err := w.notifier("n").Send(context.Background(), m); errText(err) != "unknown notifier type" {
		t.Errorf("unknown: %v", err)
	}
}

// A static app has no process: no journal lookup for how it ended, every minute.
func TestStaticAppNoJournal(t *testing.T) {
	f := newFakeHost(t)
	f.app("site", "recipe=static")
	f.ticks(3)
	if c := f.called("journalctl"); len(c) != 0 {
		t.Errorf("journalctl for a static app: %v", c)
	}
	if f.st("site.nr") != "0" {
		t.Errorf("site.nr = %q", f.st("site.nr"))
	}
}

// Two commits of one process within the same second (tandod's tick of the minute and a tick asked
// over the socket) each queue their own file; a failing notifier keeps both; when it works again
// one delivery carries both, and only the files it read are deleted.
func TestTwoCommitsSameSecond(t *testing.T) {
	f := hostWithHog(t)
	f.code = 500
	w := f.watch() // one Watch: one process, one sequence
	now := f.now.Unix()
	for i, rel := range []string{"r1", "r2"} {
		f.write("lib/watch/inbox/"+decimal.Itoa(now)+".hog."+rel, "rollback\thog\t"+rel+"\trelease "+rel+" rolled back\n")
		if err := w.Run(context.Background()); err != nil {
			t.Fatal(err)
		}
		if q := f.queueFiles("hook"); len(q) != i+1 {
			t.Fatalf("after commit %d: queue %v", i+1, q)
		}
		f.write("lib/watch/state", strings.Replace(string(readAll(f.path("lib/watch/state"))), "_nf.hook.next=", "_nf.hook.x=", 1))
	}
	// a file written after the read is not deleted with the message that did not carry it
	m := w.compose(loadSettings(f.path("none")), f.queueFiles("hook"))
	late := f.path("lib/watch/out/hook/" + decimal.Itoa(now) + ".9-9")
	f.write("lib/watch/out/hook/"+decimal.Itoa(now)+".9-9", "firing\thog\thealth\tlate\t1\n")
	removeRead(m.read)
	if q := f.queueFiles("hook"); len(q) != 1 || q[0] != late {
		t.Errorf("after removing what was read: %v", q)
	}
	os.Remove(late)
	f.write("lib/watch/inbox/"+decimal.Itoa(now)+".hog.r3", "rollback\thog\tr3\trelease r3 rolled back\n")
	f.write("lib/watch/state", "")
	f.code = 200
	f.reset()
	if err := w.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if b := f.sentBodies(); len(b) != 1 || !strings.Contains(b[0], "release r3") {
		t.Errorf("delivered: %v", b)
	}
}

// Hostile bytes in an app's detail (a lone 8-bit CSI, invalid UTF-8, controls, bidi) reach every
// notifier body as valid UTF-8 and valid JSON.
func TestHostileBytesInNotifications(t *testing.T) {
	f := newFakeHost(t)
	w := f.watch()
	evil := "x\x9b[2J\xff\xfe\x00\x1b]0;t\x07\u202eabc\xc3"
	f.write("q/1", "firing\thog\thealth\t"+clean(evil)+"\t1\n")
	f.write("q/2", "firing\thog\thealth\t"+evil+"\t1\n") // (as a shell version could have queued it)
	m := w.compose(loadSettings(f.path("none")), []string{f.path("q/1"), f.path("q/2")})
	for _, conf := range []string{"type=webhook\nurl=http://h/a\n", "type=slack\nurl=http://h/a\n",
		"type=telegram\ntoken=a:b\nchat=1\napi=http://h\n", "type=ntfy\nurl=http://h/a\n"} {
		f.reset()
		f.notifier("n", conf)
		w.notifier("n").Send(context.Background(), m)
		b := f.sends[0].body
		bad := false
		for _, x := range []string{"\x9b", "\x1b", "\x00", "\u202e"} { // (bytes, not runes)
			bad = bad || strings.Contains(b, x)
		}
		if !utf8.ValidString(b) || bad {
			t.Errorf("%s: %q", conf, b)
		}
		if strings.HasPrefix(b, "{") && !json.Valid([]byte(b)) {
			t.Errorf("%s: not JSON: %q", conf, b)
		}
		for _, h := range f.sends[0].header {
			if !utf8.ValidString(h[1]) || strings.ContainsAny(h[1], "\r\n") {
				t.Errorf("header %q", h)
			}
		}
	}
}
