package watch

import (
	"os"
	"testing"
)

// recoverNeeded sees a reserved release whose activation unit is gone, and leaves one whose unit
// runs (a queued activation) alone.
func TestRecoverNeededReservation(t *testing.T) {
	f := newFakeHost(t)
	f.app("shop")
	os.MkdirAll(f.path("opt/apps/shop/releases/20261114-170102"), 0o700)
	f.write("opt/apps/shop/state", "current=20261114-170102\nphase=idle\nstatus_20261114-170102=verified\n")
	os.Symlink("releases/20261114-170102", f.path("opt/apps/shop/current"))
	if f.watch().recoverNeeded() {
		t.Fatal("a sound app needs no recover")
	}
	os.MkdirAll(f.path("opt/apps/shop/releases/20261114-180000"), 0o700)
	f.write("cgroup/system.slice/tando-shop-act-20261114-180000.service/cgroup.events", "populated 1\nfrozen 0\n")
	if f.watch().recoverNeeded() {
		t.Fatal("a reservation whose activation runs (queued) needs no recover")
	}
	f.write("cgroup/system.slice/tando-shop-act-20261114-180000.service/cgroup.events", "populated 0\nfrozen 0\n")
	if !f.watch().recoverNeeded() {
		t.Fatal("a reservation whose activation has no process must be recovered")
	}
	os.RemoveAll(f.path("cgroup/system.slice"))
	if !f.watch().recoverNeeded() {
		t.Fatal("a reservation with no activation unit at all must be recovered")
	}
	f.write("opt/apps/shop/state", "current=20261114-170102\nphase=idle\nstatus_20261114-170102=verified\nstatus_20261114-180000=bad\n")
	if f.watch().recoverNeeded() {
		t.Fatal("a release with a status is no reservation")
	}
}

// recoverNeeded sees an operation whose result was committed but whose history line (and the
// rest after it) was not written: outcome differs from outcome_done.
func TestRecoverNeededOutcome(t *testing.T) {
	f := newFakeHost(t)
	f.app("shop")
	os.MkdirAll(f.path("opt/apps/shop/releases/20261114-170102"), 0o700)
	os.Symlink("releases/20261114-170102", f.path("opt/apps/shop/current"))
	base := "current=20261114-170102\nphase=idle\nstatus_20261114-170102=verified\noutcome=20261114-170102 rollback ok 1800000000\n"
	f.write("opt/apps/shop/state", base+"outcome_done=20261114-170102 rollback ok 1800000000\n")
	if f.watch().recoverNeeded() {
		t.Fatal("an operation written out needs no recover")
	}
	f.write("opt/apps/shop/state", base)
	if !f.watch().recoverNeeded() {
		t.Fatal("an operation whose end was not written out must be recovered")
	}
}

// recoverNeeded sees a rollback that died after its progress file (result=running) and before
// its first state write (the state is idle), and leaves one whose lock is held (it is running).
func TestRecoverNeededRollbackCut(t *testing.T) {
	f := newFakeHost(t)
	f.app("shop")
	os.MkdirAll(f.path("opt/apps/shop/releases/20261114-170102"), 0o700)
	os.Symlink("releases/20261114-170102", f.path("opt/apps/shop/current"))
	f.write("opt/apps/shop/state", "current=20261114-170102\nphase=idle\nstatus_20261114-170102=verified\n")
	f.write("opt/apps/shop/activation", "id=20261114-160000\nkind=rollback\nphase=switch\nresult=ok\n")
	if f.watch().recoverNeeded() {
		t.Fatal("a finished rollback needs no recover")
	}
	f.write("opt/apps/shop/activation", "id=20261114-160000\nkind=rollback\nphase=switch\nresult=running\n")
	if !f.watch().recoverNeeded() {
		t.Fatal("a rollback that says running, with the lock free and the state idle, must be recovered")
	}
	f.write("opt/apps/shop/activation", "id=20261114-170200\nkind=deploy\nphase=queued\nresult=running\n")
	if f.watch().recoverNeeded() {
		t.Fatal("a queued deploy that says running is not a cut rollback")
	}
}

// recoverNeeded sees an upload lease with no release id whose holder is gone (taken in an earlier
// boot, or its activate no longer runs), and leaves one a client or a live activate holds alone.
func TestRecoverNeededLeaseOrphaned(t *testing.T) {
	f := newFakeHost(t)
	f.app("shop")
	os.MkdirAll(f.path("opt/apps/shop/releases/20261114-170102"), 0o700)
	os.Symlink("releases/20261114-170102", f.path("opt/apps/shop/current"))
	f.write("opt/apps/shop/state", "current=20261114-170102\nphase=idle\nstatus_20261114-170102=verified\n")
	f.write("proc/sys/kernel/random/boot_id", "b-now\n")
	f.write("proc/4242/stat", "4242 (tando-agent) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 777 20\n")
	for _, c := range []struct {
		lease string
		want  bool
	}{
		{"token=t\nboot=b-now\n", false},                        // the client holds it (uploading)
		{"token=t\nboot=b-now\nholder=4242 777\n", false},       // its activate runs
		{"token=t\nboot=b-now\nholder=4242 778\n", true},        // that pid is another process now
		{"token=t\nboot=b-now\nholder=4343 777\n", true},        // its activate is gone
		{"token=t\nboot=b-before\n", true},                      // taken before a restart
		{"token=t\nboot=b-before\nid=20261114-180000\n", false}, // the activation's: rec_reap's
		{"token=t\n", false},                                    // an older agent's lease
	} {
		f.write("opt/apps/shop/upload", c.lease)
		if got := f.watch().recoverNeeded(); got != c.want {
			t.Errorf("lease %q: recoverNeeded=%v, want %v", c.lease, got, c.want)
		}
	}
}
