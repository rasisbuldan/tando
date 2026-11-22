package watch

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"tando/srv/internal/decimal"
)

func careSummary(at int64, rows ...string) string {
	return "# tando-host summary, format 1\nsummary\t1\t" + decimal.Itoa(at) + "\t0\t1\t1\t0\tweb1\n" + strings.Join(rows, "\n") + "\n"
}

func TestHostcareAlerts(t *testing.T) {
	f := hostWithHog(t)
	now := f.now.Unix()
	bad := "alert\texposed\tbad\t" + decimal.Itoa(now) + "\thigh\t0\tport 5432 is open to the internet"
	low := "alert\tssh\tbad\t" + decimal.Itoa(now) + "\tlow\t0\tssh accepts passwords"
	f.write("lib/hostcare/summary", careSummary(now, bad, low, "alert\tclock\tok\t0\tnormal\t0\t", "alert\tmade-up\tbad\t0\thigh\t0\tx", "future\trow"))
	f.ticks(2)
	if f.st("_host.exposed.st") != "firing" || f.st("_host.ssh.st") != "firing" || f.st("_host.made-up.st") != "" {
		t.Fatalf("state %v", f.state())
	}
	if f.countSent("host/exposed: port 5432 is open to the internet") != 1 || f.countSent("host/ssh (low): ssh accepts passwords") != 1 {
		t.Errorf("%v", f.sentBodies())
	}
	// a stale summary neither resolves nor fires
	f.write("lib/hostcare/summary", careSummary(now-4*3600, "alert\texposed\tok\t0\thigh\t0\t", "alert\tunits\tbad\t1\tnormal\t0\tx"))
	f.ticks(2)
	if f.st("_host.exposed.st") != "firing" || f.st("_host.units.st") == "firing" {
		t.Errorf("stale summary judged: %v", f.state())
	}
	if f.st("_host.care.st") != "firing" || f.countSent("host/care: the host checks last ran 4h") != 1 {
		t.Errorf("stale summary not reported: %v %v", f.state(), f.sentBodies())
	}
	// a summary from the future is not fresh either
	f.write("lib/hostcare/summary", careSummary(f.now.Unix()+3600, "alert\texposed\tok\t0\thigh\t0\t"))
	f.ticks(2)
	if f.st("_host.exposed.st") != "firing" {
		t.Errorf("future summary judged: %v", f.state())
	}
	// fresh and ok (or off) resolves
	f.write("lib/hostcare/summary", careSummary(f.now.Unix(), "alert\texposed\tok\t0\thigh\t0\t", "alert\tssh\toff\t0\tlow\t0\t"))
	f.ticks(2)
	if f.st("_host.exposed.st") == "firing" || f.st("_host.ssh.st") == "firing" || f.st("_host.care.st") == "firing" {
		t.Errorf("not resolved: %v", f.state())
	}
	// host care removed while something fires: it resolves
	f.write("lib/hostcare/summary", careSummary(f.now.Unix(), "alert\tunits\tbad\t1\tnormal\t0\tx.service failed"))
	f.ticks(2)
	if f.st("_host.units.st") != "firing" {
		t.Fatalf("state %v", f.state())
	}
	os.Remove(f.path("lib/hostcare/summary"))
	f.ticks(2)
	if f.st("_host.units.st") == "firing" {
		t.Errorf("not resolved after removal: %v", f.state())
	}
}

func TestOffsiteAlerts(t *testing.T) {
	f := hostWithHog(t)
	now := f.now.Unix()
	f.write("lib/offsite/state/hog", "enabled=1\nalert_hours=6\noldest_pending="+decimal.Itoa(now-7*3600)+"\noldest_pending_id=20261115-010000\ncreds=ok\n")
	f.ticks(2)
	if f.st("hog.offsite.st") != "firing" || !strings.Contains(f.st("hog.offsite.det"), "backup 20261115-010000 not offsite after") {
		t.Fatalf("state %v", f.state())
	}
	g := hostWithHog(t)
	g.write("lib/offsite/state/hog", "enabled=1\nalert_hours=6\noldest_pending=0\ncreds=failing\ncreds_error=403 forbidden\n")
	g.ticks(2)
	if g.st("hog.offsite.st") != "firing" || !strings.Contains(g.st("hog.offsite.det"), "offsite credentials fail: 403 forbidden") {
		t.Errorf("state %v", g.state())
	}
	f.write("lib/offsite/state/hog", "enabled=1\noldest_pending=0\ncreds=ok\n")
	f.ticks(2)
	if f.st("hog.offsite.st") == "firing" {
		t.Errorf("not resolved: %v", f.state())
	}
	g.write("lib/offsite/state/hog", "enabled=0\n") // turned off while firing
	g.ticks(2)
	if g.st("hog.offsite.st") == "firing" {
		t.Errorf("not resolved when turned off: %v", g.state())
	}
}

// A run that died between the scan and its commit left its newerr rows in the kept file: the
// next run sends them, and removes the file once it has committed.
func TestNewErrorKeptAcrossDeadRun(t *testing.T) {
	f := hostWithHog(t)
	f.write("opt/bin/tando-logs", "#!fake\n")
	os.Chmod(f.path("opt/bin/tando-logs"), 0o755)
	now := f.now.Unix()
	p := f.watch().newErrPendingPath()
	os.MkdirAll(filepath.Dir(p), 0o700)
	os.WriteFile(p, []byte("newerr\thog\taa\t"+decimal.Itoa(now-30)+"\t2\ttrace\tTypeError at faa (server.js)\n"), 0o600)
	f.scan = "scan\thog\t10\t0\t0\t0\t0\t0\t0\nrelease\thog\t20261115-013512\t" + decimal.Itoa(now-120) + "\n"
	f.tick()
	if n := f.countSent("NEW ERROR hog: new error after release 20261115-013512"); n != 1 {
		t.Errorf("%d notices, want 1: %v", n, f.sentBodies())
	}
	if _, err := os.Stat(p); err == nil {
		t.Errorf("kept file still there after the commit")
	}
	f.tick()
	if n := f.countSent("NEW ERROR hog: new error after release 20261115-013512"); n != 1 {
		t.Errorf("sent again: %d", n)
	}
}

// A failed restore drill (tando backup drill) fires "drill" with the recorded reason; the next one
// that works resolves it. An app with backups off is not judged.
func TestRestoreDrillAlert(t *testing.T) {
	f := newFakeHost(t)
	f.app("hog", "backup=daily")
	f.notifier("hook", "type=webhook\nurl=http://127.0.0.1:9/hook/S3CR3T\n")
	f.write("opt/apps/hog/state", "current=20261114-170102\nphase=idle\nbackup_daily_ok="+decimal.Itoa(f.now.Unix())+"\ndrill_result=fail\ndrill_why=pg_restore exited with 1\n")
	f.ticks(2)
	if f.st("hog.drill.st") != "firing" || !strings.Contains(f.st("hog.drill.det"), "restore drill of the last backup failed: pg_restore exited with 1") {
		t.Fatalf("state %v", f.state())
	}
	f.write("opt/apps/hog/state", "current=20261114-170102\nphase=idle\nbackup_daily_ok="+decimal.Itoa(f.now.Unix())+"\ndrill_result=ok\n")
	f.ticks(2)
	if f.st("hog.drill.st") == "firing" {
		t.Errorf("not resolved after a drill that worked: %v", f.state())
	}
}
