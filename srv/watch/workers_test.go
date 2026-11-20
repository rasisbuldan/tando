package watch

import (
	"slices"
	"strings"
	"testing"
)

const (
	workerFiring   = `"state":"firing","app":"hog","check":"worker.q"`
	workerResolved = `"state":"resolved","app":"hog","check":"worker.q"`
)

// workerAt sets the worker's unit: its state and its automatic restarts so far.
func (f *fakeHost) workerAt(app, n, active, sub, restarts string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.units[workerUnit(app, n)] = map[string]string{"ActiveState": active, "SubState": sub, "NRestarts": restarts,
		"Result": "exit-code", "ExecMainCode": "1", "ExecMainStatus": "1"}
}

// A worker that keeps exiting fires after two runs with new restarts, once; it resolves when it
// stays up; one the live release no longer has resolves and its state goes.
func TestWorkerThatKeepsExitingFiresAndResolves(t *testing.T) {
	f := newFakeHost(t)
	f.app("hog", "worker.q=node w.js", "worker.q.memory=96M")
	f.notifier("hook", "type=webhook\nurl=http://127.0.0.1:9/hook\n")
	f.workerAt("hog", "q", "active", "running", "0")
	f.ticks(2)
	if n := len(f.sentBodies()); n != 0 {
		t.Fatalf("a worker that runs: %d sent", n)
	}
	if c := f.called("systemctl show"); len(c) == 0 || !slices.Contains(c[len(c)-1], "tando-hog_worker-q.service") {
		t.Fatalf("the worker's unit is not asked in the run's systemctl call: %v", c)
	}
	f.workerAt("hog", "q", "activating", "auto-restart", "3")
	f.tick()
	if f.countSent(workerFiring) != 0 {
		t.Fatalf("fired after one run with restarts")
	}
	f.workerAt("hog", "q", "active", "running", "5")
	f.tick()
	if f.st("hog.worker.q.st") != "firing" || f.countSent(workerFiring) != 1 {
		t.Fatalf("not fired after two runs with restarts: %q %v", f.st("hog.worker.q.st"), f.sentBodies())
	}
	if d := f.st("hog.worker.q.det"); !strings.Contains(d, "worker q keeps exiting: 2 automatic restarts") ||
		!strings.Contains(d, "exit status 1") || !strings.Contains(d, "--worker q") {
		t.Errorf("detail %q", d)
	}
	f.ticks(2) // no new restart, running: resolves
	if f.st("hog.worker.q.st") != "ok" || f.countSent(workerResolved) != 1 {
		t.Fatalf("not resolved when it stayed up: %q %v", f.st("hog.worker.q.st"), f.sentBodies())
	}
	// fires again, then the worker is removed from the live release: resolved, state dropped
	f.workerAt("hog", "q", "active", "running", "7")
	f.tick()
	f.workerAt("hog", "q", "active", "running", "9")
	f.tick()
	if f.countSent(workerFiring) != 2 {
		t.Fatalf("second firing: %v", f.sentBodies())
	}
	f.app("hog", "start=node server.js")
	f.ticks(2)
	if f.countSent(workerResolved) != 2 {
		t.Fatalf("a removed worker's alert did not resolve: %v", f.sentBodies())
	}
	for k := range f.state() {
		if strings.HasPrefix(k, "hog.worker.q.") && !strings.HasSuffix(k, ".st") && !strings.HasSuffix(k, ".nt") && !strings.HasSuffix(k, ".ns") && !strings.HasSuffix(k, ".fl") && !strings.HasSuffix(k, ".flap") {
			t.Errorf("state left for a removed worker: %s", k)
		}
	}
}

// A stopped app does not judge its workers (they are stopped on purpose).
func TestWorkerOfStoppedAppIsNotJudged(t *testing.T) {
	f := newFakeHost(t)
	f.app("hog", "worker.q=node w.js")
	f.workerAt("hog", "q", "active", "running", "0")
	f.ticks(2)
	f.write("opt/apps/hog/state", "current=20261114-170102\nstatus_20261114-170102=verified\nstopped=1\n")
	for _, n := range []string{"2", "4", "6"} {
		f.workerAt("hog", "q", "inactive", "dead", n)
		f.tick()
	}
	if f.st("hog.worker.q.st") == "firing" || len(f.sentBodies()) != 0 {
		t.Errorf("a stopped app's worker fired: %v", f.sentBodies())
	}
}
