package watch

import (
	"slices"
	"testing"
)

// journalReads counts the journalctl runs of countRestarts for one app.
func (f *fakeHost) journalReads(app string) int {
	n := 0
	for _, c := range f.called("journalctl") {
		if slices.Contains(c, "tando-"+app+".service") && slices.Contains(c, "process exited, code=") {
			n++
		}
	}
	return n
}

// countRestarts reads systemd's exit line from the journal once per change of the unit's state
// and restart count: never for a static or stopped app, once for an app that stays failed, and a
// real restart is still counted (and read).
func TestRestartsJournalOncePerChange(t *testing.T) {
	f := newFakeHost(t)
	f.app("site", "recipe=static")
	f.app("off")
	f.write("opt/apps/off/state", "current=20261114-170102\nphase=idle\nstopped=1\n")
	f.unit("tando-off.service", "inactive", "dead", "0")
	f.app("dead")
	f.unit("tando-dead.service", "failed", "failed", "5")
	f.units["tando-dead.service"]["Result"] = "exit-code"
	f.app("web")
	f.journal["process exited, code="] = "x.service: Main process exited, code=exited, status=3/NOTIMPLEMENTED\n"
	f.ticks(6)
	if n := f.journalReads("site") + f.journalReads("off"); n != 0 {
		t.Errorf("a static or stopped app read the journal %d times in 6 ticks", n)
	}
	if n := f.journalReads("dead"); n != 1 {
		t.Errorf("a failed app read the journal %d times in 6 ticks, want once", n)
	}
	if d := f.st("dead.down.det"); d != "failed (exit-code, exit status 3); systemd gave up restarting it" {
		t.Errorf("dead: the cached exit is not in the details: %q", d)
	}
	if n := f.journalReads("web"); n != 0 {
		t.Errorf("a running app read the journal %d times", n)
	}
	// a real restart: counted, and its exit read once
	f.unit("tando-web.service", "active", "running", "1")
	f.ticks(3)
	if f.st("web.nr") != "1" || f.st("web.rt") == "" {
		t.Errorf("the restart was not counted: nr %q rt %q", f.st("web.nr"), f.st("web.rt"))
	}
	if n := f.journalReads("web"); n != 1 {
		t.Errorf("a restarted app read the journal %d times, want once", n)
	}
	// systemd gives up on it later: one more read for the new state
	f.unit("tando-web.service", "failed", "failed", "1")
	f.ticks(3)
	if n := f.journalReads("web"); n != 2 {
		t.Errorf("after a new state: %d reads, want 2", n)
	}
}
