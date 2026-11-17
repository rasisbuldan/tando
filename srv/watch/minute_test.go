package watch

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"tando/srv/internal/decimal"
	"tando/srv/internal/kvfile"
	"tando/srv/internal/out"
)

// runAgain runs the checks a second time in the same minute (tandod's tick and one asked for, a
// degraded daemon's retry after the fallback, the agent's run after a rollback).
func (f *fakeHost) runAgain() {
	f.t.Helper()
	f.setUptime()
	if err := f.watch().Run(context.Background()); err != nil {
		f.t.Fatal(err)
	}
}

// Streaks count minutes, not runs: two runs a minute fire after health_fails minutes, resolve
// after resolve_after minutes, and the liveness restart waits its minutes too.
func TestTwoRunsAMinuteCountOnce(t *testing.T) {
	f := hostWithHog(t)
	f.settings("liveness=0")
	f.probe["http://hog.localhost/health"] = probeRes{code: 500}
	for range 2 { // 2 minutes, 2 runs each
		f.runAgain()
		f.tick()
	}
	if st, n := f.st("hog.health.st"), f.st("hog.health.n"); st != "pending" || n != "2" {
		t.Fatalf("after 2 minutes of 2 runs: %s n=%s (fired early?)", st, n)
	}
	f.runAgain()
	f.tick()
	if f.st("hog.health.st") != "firing" {
		t.Fatalf("not firing after the 3rd minute")
	}
	delete(f.probe, "http://hog.localhost/health")
	f.runAgain() // a good run ...
	f.tick()     // ... and another in the same minute: one good minute
	if f.st("hog.health.st") != "firing" || f.st("hog.health.okn") != "1" {
		t.Errorf("resolved after one good minute (2 runs): %s okn=%s", f.st("hog.health.st"), f.st("hog.health.okn"))
	}
	f.tick()
	if f.st("hog.health.st") != "ok" {
		t.Errorf("not resolved after 2 good minutes")
	}
}

func TestLivenessCountsMinutes(t *testing.T) {
	f := hostWithHog(t)
	f.probe["http://hog.localhost/health"] = probeRes{exit: 28}
	for range 2 { // 2 minutes, 3 runs each: still below liveness=3
		f.runAgain()
		f.runAgain()
		f.tick()
	}
	if n := len(f.called("systemd-run")); n != 0 {
		t.Fatalf("restarted after 2 minutes (6 runs): %d", n)
	}
	f.tick()
	if n := len(f.called("systemd-run")); n != 1 {
		t.Errorf("not restarted after 3 minutes: %d", n)
	}
}

// The monitor check: tandod degraded (its state file), failed, restarting again and again, or
// restarted twice since the last run is a host alert; stopped on purpose is not.
func TestMonitorCheck(t *testing.T) {
	for _, tt := range []struct {
		name  string
		state string
		unit  map[string]string
		fire  string
	}{
		{"healthy", "", map[string]string{"ActiveState": "active", "NRestarts": "0"}, ""},
		{"degraded", "degraded=1799999000\nreason=panic: boom\n", map[string]string{"ActiveState": "active", "NRestarts": "0"},
			"tandod handed the checks to the timer 16m 40s ago (panic: boom)"},
		{"failed", "", map[string]string{"ActiveState": "failed", "Result": "exit-code", "NRestarts": "5"}, "tandod is not running (failed: exit-code)"},
		{"restart loop", "", map[string]string{"ActiveState": "activating", "SubState": "auto-restart", "Result": "exit-code", "NRestarts": "7"},
			"tandod keeps restarting (7 restarts; exit-code)"},
		{"stopped", "", map[string]string{"ActiveState": "inactive", "NRestarts": "0"}, ""},
	} {
		f := newFakeHost(t)
		f.write("units/tandod.service", "x")
		u := map[string]string{"SubState": "", "Result": "success", "MemoryMax": "", "ExecMainCode": "0", "ExecMainStatus": "0"}
		for k, v := range tt.unit {
			u[k] = v
		}
		f.units["tandod.service"] = u
		if tt.state != "" {
			f.write("run/tandod.health", tt.state)
		}
		f.tick()
		st, det := f.st("_host.monitor.st"), f.st("_host.monitor.det")
		if tt.fire == "" && st == "firing" || tt.fire != "" && (st != "firing" || !strings.HasPrefix(det, tt.fire)) {
			t.Errorf("%s: %s %q", tt.name, st, det)
		}
	}
	// restarted twice since the last run
	f := newFakeHost(t)
	f.write("units/tandod.service", "x")
	f.units["tandod.service"] = map[string]string{"ActiveState": "active", "NRestarts": "1"}
	f.tick()
	f.units["tandod.service"]["NRestarts"] = "3"
	f.tick()
	if f.st("_host.monitor.st") != "firing" || !strings.HasPrefix(f.st("_host.monitor.det"), "tandod restarted 2 times since the last run") {
		t.Errorf("restarts: %s %q", f.st("_host.monitor.st"), f.st("_host.monitor.det"))
	}
}

// A lock held for good: a run that cannot get it tells every notifier straight away (once an
// hour), says so on stderr, and doctor has a fail row; a fresh holder is not reported.
func TestStuckLock(t *testing.T) {
	f := hostWithHog(t)
	w := f.watch()
	pid := decimal.Itoa(int64(os.Getpid()))
	f.write("proc/"+pid+"/stat", pid+" (stuckproc) S"+strings.Repeat(" 0", 18)+" 4242 0\n") // (start time: field 22)
	f.write("proc/"+pid+"/comm", "stuckproc\n")
	l, err := w.takeLock(time.Second) // this process holds it ...
	if err != nil {
		t.Fatal(err)
	}
	defer l.Release()
	b, _ := os.ReadFile(f.path("lib/watch/lock.holder"))
	p := strings.Fields(string(b))
	if len(p) != 3 || p[0] != pid || p[1] != "4242" {
		t.Fatalf("holder %q", b)
	}
	if _, stuck := w.stuckHolder(f.now.Unix() + 60); stuck {
		t.Error("a holder of a minute reported stuck")
	}
	f.now = f.now.Add(10 * time.Minute) // ... for 10 minutes
	f.reset()
	w = f.watch()
	w.lockStuck(context.Background(), loadSettings(w.Conf))
	if len(f.sends) != 1 || !strings.Contains(f.sends[0].body, "no checks run: the lock of the checks is held for 10m 0s by pid "+p[0]+" (stuckproc)") {
		t.Fatalf("sent %v", f.sentBodies())
	}
	w.lockStuck(context.Background(), loadSettings(w.Conf))
	if len(f.sends) != 1 {
		t.Errorf("told twice within an hour")
	}
	o, _ := do(func(o *out.Writer) error { w.Doctor(context.Background(), o); return nil })
	if !strings.Contains(o, "check\tfail\talerts lock\tthe lock of the checks is held for 10m 0s by pid "+p[0]) {
		t.Errorf("doctor %q", o)
	}
}

// Temp files of a run killed between writing and linking go after 10 minutes.
func TestSweepTemp(t *testing.T) {
	f := hostWithHog(t)
	f.write("lib/watch/out/hook/.123.1.tmp", "x")
	f.write("lib/watch/out/hook/.124.1.tmp", "x")
	old := time.Now().Add(-20 * time.Minute)
	os.Chtimes(f.path("lib/watch/out/hook/.123.1.tmp"), old, old)
	f.now = time.Now()
	f.watch().sweepTemp()
	if fileExists(f.path("lib/watch/out/hook/.123.1.tmp")) || !fileExists(f.path("lib/watch/out/hook/.124.1.tmp")) {
		t.Error("sweep")
	}
	_ = kvfile.Load
}

func fileExists(p string) bool { _, err := os.Stat(p); return err == nil }

// sample_seconds=0 (the test suites): every run counts.
func TestSampleSecondsZero(t *testing.T) {
	f := hostWithHog(t)
	f.settings("liveness=0", "sample_seconds=0")
	f.probe["http://hog.localhost/health"] = probeRes{code: 500}
	f.runAgain()
	f.runAgain()
	f.runAgain()
	if f.st("hog.health.st") != "firing" {
		t.Errorf("3 runs with sample_seconds=0: %s", f.st("hog.health.st"))
	}
}
