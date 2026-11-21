package watch

import (
	"os"
	"slices"
	"strings"
	"testing"
	"time"

	"tando/srv/internal/decimal"
	"tando/srv/internal/out"
)

// jobRan sets how the job's unit last ended, ago seconds before now (a new run each call: the
// time it ended is what tells runs apart).
func (f *fakeHost) jobRan(app, job, active, result, code, status string, ago int64) {
	f.mu.Lock()
	defer f.mu.Unlock()
	ended := (f.now.Unix() - f.boot - ago) * 1000000
	f.units[jobUnit(app, job)] = map[string]string{"ActiveState": active, "SubState": "dead", "Result": result,
		"ExecMainCode": code, "ExecMainStatus": status, "InactiveEnterTimestampMonotonic": decimal.Itoa(ended)}
}

func hostWithJob(t *testing.T) *fakeHost {
	f := newFakeHost(t)
	f.app("hog", "job.nightly=daily | ./nightly.sh", "job.other=hourly | true")
	f.notifier("hook", "type=webhook\nurl=http://127.0.0.1:9/hook\n")
	return f
}

const (
	jobFiring   = `"state":"firing","app":"hog","check":"job.nightly"`
	jobResolved = `"state":"resolved","app":"hog","check":"job.nightly"`
)

func TestJobNeverRanOrRunningIsNoFailure(t *testing.T) {
	f := hostWithJob(t)
	f.ticks(2) // never ran: systemd knows no run of the unit
	f.mu.Lock()
	f.units[jobUnit("hog", "nightly")] = map[string]string{"ActiveState": "activating", "SubState": "start", "Result": "success",
		"InactiveEnterTimestampMonotonic": "0"}
	f.mu.Unlock()
	f.ticks(2) // running for the first time
	f.jobRan("hog", "nightly", "inactive", "success", "1", "0", 30)
	f.ticks(2)
	if n := len(f.sentBodies()); n != 0 || f.st("hog.job.nightly.st") != "" {
		t.Errorf("%d sent, state %q; want nothing", n, f.st("hog.job.nightly.st"))
	}
	// the job units are asked in the run's one systemctl call
	if c := f.called("systemctl show"); len(c) == 0 || !slices.Contains(c[len(c)-1], "tando-hog_job-nightly.service") ||
		!slices.Contains(c[len(c)-1], "tando-hog_job-other.service") {
		t.Errorf("job units not asked: %v", c)
	}
	f.reset()
	f.tick()
	if n := len(f.called("systemctl show")); n != 1 {
		t.Errorf("%d systemctl show calls in a run, want 1", n)
	}
}

func TestJobFailureFiresOncePerFailedRunAndResolvesOnSuccess(t *testing.T) {
	f := hostWithJob(t)
	f.ticks(2)
	f.jobRan("hog", "nightly", "failed", "exit-code", "1", "3", 120)
	want := "job nightly failed at " + f.now.Add(-2*time.Minute).UTC().Format("01-02 15:04") + " UTC: exit status 3; tando jobs run nightly -a hog"
	f.tick()
	if f.st("hog.job.nightly.st") != "firing" || f.countSent(jobFiring) != 1 {
		t.Fatalf("not fired once at the first run after the failure: %q %v", f.st("hog.job.nightly.st"), f.sentBodies())
	}
	if d := f.st("hog.job.nightly.det"); !strings.HasPrefix(d, want) {
		t.Errorf("detail %q, want it to start with %q", d, want)
	}
	f.ticks(5)
	if n := len(f.sentBodies()); n != 1 {
		t.Fatalf("the same failed run was told %d times", n)
	}
	// the job starts again: while it runs nothing changes
	f.mu.Lock()
	f.units[jobUnit("hog", "nightly")]["ActiveState"] = "activating"
	f.mu.Unlock()
	f.ticks(2)
	if f.st("hog.job.nightly.st") != "firing" || len(f.sentBodies()) != 1 {
		t.Fatalf("a running job changed the alert: %q, %d sent", f.st("hog.job.nightly.st"), len(f.sentBodies()))
	}
	// it fails again: a second message, with this run's exit status
	f.jobRan("hog", "nightly", "failed", "exit-code", "1", "4", 10)
	f.tick()
	if f.countSent(jobFiring) != 2 || !strings.Contains(f.st("hog.job.nightly.det"), "exit status 4") {
		t.Fatalf("second failed run: %d firing messages, detail %q", f.countSent(jobFiring), f.st("hog.job.nightly.det"))
	}
	if b := f.sentBodies(); !strings.Contains(b[len(b)-1], "exit status 4") {
		t.Errorf("the second message does not carry the second run's status: %s", b[len(b)-1])
	}
	f.ticks(3)
	if n := f.count(f.history(), "fire hog job.nightly"); n != 2 || len(f.sentBodies()) != 2 {
		t.Fatalf("history has %d firings, %d sent; want 2 and 2", n, len(f.sentBodies()))
	}
	// its next run succeeds: resolved at once (one good sample), once
	f.jobRan("hog", "nightly", "inactive", "success", "1", "0", 5)
	f.tick()
	if f.st("hog.job.nightly.st") != "ok" || f.countSent(jobResolved) != 1 {
		t.Fatalf("not resolved by the success: %q %v", f.st("hog.job.nightly.st"), f.sentBodies())
	}
	f.ticks(3)
	if n := len(f.sentBodies()); n != 3 {
		t.Errorf("%d messages in all, want 3 (fired, fired again, resolved)", n)
	}
	// the other job never ran and never said anything
	for k := range f.state() {
		if strings.HasPrefix(k, "hog.job.other.") {
			t.Errorf("state for a job that never ran: %s", k)
		}
	}
}

// Apps alpha (job job-x) and alpha-job (job x): the units of the form before were the same,
// tando-alpha-job-job-x... and tando-alpha-job-x was both alpha's job x and app alpha-job-x's
// service. Each job's alert follows its own unit only.
func TestJobUnitsOfSimilarAppsAreTheirOwn(t *testing.T) {
	f := newFakeHost(t)
	f.app("alpha", "job.job-x=daily | true", "job.x=daily | true")
	f.app("alpha-job", "job.x=daily | true")
	f.notifier("hook", "type=webhook\nurl=http://127.0.0.1:9/hook\n")
	seen := map[string]bool{}
	for _, u := range []string{jobUnit("alpha", "job-x"), jobUnit("alpha", "x"), jobUnit("alpha-job", "x"),
		"tando-alpha.service", "tando-alpha-job.service", "tando-alpha-job-x.service"} {
		if seen[u] {
			t.Fatalf("two units named %s", u)
		}
		seen[u] = true
	}
	f.ticks(2)
	f.jobRan("alpha-job", "x", "failed", "timeout", "2", "15", 60)
	f.tick()
	if f.st("alpha-job.job.x.st") != "firing" || f.st("alpha.job.x.st") != "" || f.st("alpha.job.job-x.st") != "" {
		t.Fatalf("alpha-job's failed job x: alpha-job %q, alpha x %q, alpha job-x %q", f.st("alpha-job.job.x.st"),
			f.st("alpha.job.x.st"), f.st("alpha.job.job-x.st"))
	}
	if d := f.st("alpha-job.job.x.det"); !strings.Contains(d, "killed by its timeout") {
		t.Errorf("detail %q", d)
	}
}

func TestJobFailureDetails(t *testing.T) {
	for _, tt := range []struct{ result, code, status, want string }{
		{"exit-code", "1", "1", "exit status 1;"},
		{"exit-code", "1", "127", "exit status 127;"},
		{"timeout", "2", "15", "killed by its timeout;"},
		{"oom-kill", "2", "9", "killed at its memory limit 96M;"},
		{"signal", "2", "9", "killed by SIGKILL;"},
		{"core-dump", "3", "11", "core dumped (SIGSEGV);"},
		{"resources", "0", "0", "it could not run (resources);"},
	} {
		f := hostWithJob(t)
		f.jobRan("hog", "nightly", "failed", tt.result, tt.code, tt.status, 60)
		f.tick()
		if d := f.st("hog.job.nightly.det"); !strings.Contains(d, ": "+tt.want) || f.countSent(jobFiring) != 1 {
			t.Errorf("%s: detail %q, want %q; sent %v", tt.result, d, tt.want, f.sentBodies())
		}
	}
}

func TestJobRemovedDropsItsAlert(t *testing.T) {
	f := hostWithJob(t)
	f.jobRan("hog", "nightly", "failed", "exit-code", "1", "1", 60)
	f.tick()
	if f.countSent(jobFiring) != 1 {
		t.Fatalf("not fired: %v", f.sentBodies())
	}
	// the next release has no such job (the agent removes the unit; systemd answers "inactive")
	f.app("hog", "job.other=hourly | true")
	f.mu.Lock()
	delete(f.units, jobUnit("hog", "nightly"))
	f.mu.Unlock()
	f.tick()
	if f.countSent(jobResolved) != 1 || !strings.Contains(strings.Join(f.sentBodies(), ""), "the job is no longer scheduled") {
		t.Fatalf("no resolve for the removed job: %v", f.sentBodies())
	}
	for k, v := range f.state() {
		if strings.HasPrefix(k, "hog.job.nightly.") && k != "hog.job.nightly.st" && k != "hog.job.nightly.fl" {
			t.Errorf("left in the state: %s=%s", k, v)
		}
	}
	if st := f.st("hog.job.nightly.st"); st != "ok" && st != "" {
		t.Errorf("state %q", st)
	}
	f.ticks(3)
	if n := len(f.sentBodies()); n != 2 {
		t.Errorf("%d messages, want 2", n)
	}
	// once its firing is older than the flap window nothing of it is left
	f.now = f.now.Add(2 * time.Hour)
	f.tick()
	for k := range f.state() {
		if strings.HasPrefix(k, "hog.job.") {
			t.Errorf("still in the state after the flap window: %s", k)
		}
	}
}

// The scheduled jobs are those of the live release (apps/<app>/jobs/<id>), not app.conf's: a
// deploy that failed leaves its jobs in app.conf, and they are not scheduled.
func TestJobsAreThoseOfTheLiveRelease(t *testing.T) {
	f := newFakeHost(t)
	f.app("hog", "job.new=daily | true")
	f.write("opt/apps/hog/jobs/20261114-170102", "job.old=daily | true\n")
	if got := f.watch().jobsOf("hog"); !slices.Equal(got, []string{"old"}) {
		t.Errorf("jobs %v, want [old]", got)
	}
	os.Remove(f.path("opt/apps/hog/jobs/20261114-170102"))
	if got := f.watch().jobsOf("hog"); !slices.Equal(got, []string{"new"}) {
		t.Errorf("without the release's file: %v, want [new]", got)
	}
	f.write("opt/apps/hog/app.conf", "recipe=node\njob.Bad Name=daily | true\njob.ok-1=daily | true\n")
	if got := f.watch().jobsOf("hog"); !slices.Equal(got, []string{"ok-1"}) {
		t.Errorf("names: %v, want [ok-1]", got)
	}
	f.write("opt/apps/hog/state", "phase=idle\n")
	if got := f.watch().jobsOf("hog"); got != nil {
		t.Errorf("no release: %v, want none", got)
	}
}

func TestJobCheckOffAndTurnedOffWhileFiring(t *testing.T) {
	f := hostWithJob(t)
	f.settings("hog.job=off")
	f.jobRan("hog", "nightly", "failed", "exit-code", "1", "1", 60)
	f.ticks(2)
	if n := len(f.sentBodies()); n != 0 || f.st("hog.job.nightly.st") != "" {
		t.Fatalf("hog.job=off: %d sent, state %q", n, f.st("hog.job.nightly.st"))
	}
	f.settings()
	f.tick()
	if f.countSent(jobFiring) != 1 {
		t.Fatalf("on again: %v", f.sentBodies())
	}
	f.settings("job=off")
	f.tick()
	if f.countSent(jobResolved) != 1 || !strings.Contains(strings.Join(f.sentBodies(), ""), "the check was turned off") {
		t.Errorf("turned off while firing: %v", f.sentBodies())
	}
}

func TestJobFailingEveryRunFlapsInsteadOfPaging(t *testing.T) {
	f := hostWithJob(t)
	for i := range 5 {
		f.jobRan("hog", "nightly", "failed", "exit-code", "1", decimal.Itoa(int64(i+1)), 1)
		f.tick()
	}
	// flap_max=3: two firing messages, then one flapping notice, then silence
	if a, b := f.countSent(jobFiring), f.countSent(`"state":"flap","app":"hog","check":"job.nightly"`); a != 2 || b != 1 {
		t.Errorf("%d firing and %d flapping messages, want 2 and 1: %v", a, b, f.sentBodies())
	}
}

func TestJobAlertSurvivesARebootUntilTheJobSucceeds(t *testing.T) {
	f := hostWithJob(t)
	f.settings("notify_reboot=no", "boot_grace=0")
	f.jobRan("hog", "nightly", "failed", "exit-code", "1", "1", 60)
	f.tick()
	f.mu.Lock()
	delete(f.units, jobUnit("hog", "nightly")) // systemd after a restart: no run known
	f.mu.Unlock()
	f.ticks(3)
	if f.st("hog.job.nightly.st") != "firing" || len(f.sentBodies()) != 1 {
		t.Fatalf("after the restart: %q, %d sent", f.st("hog.job.nightly.st"), len(f.sentBodies()))
	}
	f.jobRan("hog", "nightly", "inactive", "success", "1", "0", 5)
	f.tick()
	if f.countSent(jobResolved) != 1 {
		t.Errorf("not resolved: %v", f.sentBodies())
	}
}

// ---- PostgreSQL ----

// pgAnswer is psql's answer: the server's row (max_connections 20, 3 + 0 reserved) and one role
// row per "role limit conns".
func pgAnswer(clients int, roles ...string) string {
	s := "m|20|3|0|" + decimal.Itoa(int64(clients)) + "\n"
	for _, r := range roles {
		p := strings.Fields(r)
		s += "r|" + p[0] + "|" + p[1] + "|0|" + p[2] + "\n"
	}
	return s
}

func hostWithDB(t *testing.T) *fakeHost {
	f := newFakeHost(t)
	f.app("hog", "database=postgres")
	f.app("plain")
	f.notifier("hook", "type=webhook\nurl=http://127.0.0.1:9/hook\n")
	f.pg = pgAnswer(2, "tando_hog 10 2")
	f.pgSizes = "d|tando_hog|8388608\n"
	return f
}

const (
	connsFiring = `"state":"firing","app":"hog","check":"db_conns"`
	pgFiring    = `"state":"firing","app":"host","check":"postgres"`
)

func TestPostgresAskedOnlyWithADatabaseOnceARunWithTimeouts(t *testing.T) {
	f := newFakeHost(t)
	f.app("plain")
	f.ticks(3)
	if len(f.pgCmds) != 0 {
		t.Fatalf("psql started on a host without a database app: %v", f.pgCmds)
	}
	f = hostWithDB(t)
	f.ticks(11)
	if len(f.pgCmds) != 11 {
		t.Fatalf("%d psql calls in 11 runs, want one a run", len(f.pgCmds))
	}
	sizes := 0
	for _, c := range f.pgCmds {
		if slices.Contains(c.Argv, "--command="+pgSizesSQL) {
			sizes++
		}
		if c.User != "postgres" || c.Timeout <= 0 || c.Timeout > 10*time.Second || !slices.Contains(c.Env, "PGCONNECT_TIMEOUT=3") ||
			!slices.Contains(c.Env, "PGOPTIONS=-c statement_timeout=4000") || c.Argv[len(c.Argv)-1] != "--command="+pgConnsSQL {
			t.Fatalf("psql call without its user, timeouts or with the connections not last: %+v", c)
		}
	}
	if sizes != 2 { // disk_every=10: at the first run and ten minutes later
		t.Errorf("sizes asked %d times in 11 minutes, want 2", sizes)
	}
	if vs := f.vstate(); vs["pgsz.hog"] != "8388608" || vs["pgc.hog"] != "2" || vs["pgl.hog"] != "10" || vs["pgc.plain"] != "" {
		t.Errorf("volatile state: %v", vs)
	}
	if n := len(f.sentBodies()); n != 0 {
		t.Errorf("%d sent on a healthy server", n)
	}
}

func TestDBConnsThresholdWindowAndResolve(t *testing.T) {
	f := hostWithDB(t)
	f.pg = pgAnswer(7, "tando_hog 10 7")
	f.ticks(8)
	if f.st("hog.db_conns.st") != "" {
		t.Fatalf("7 of 10 (below 80%%): state %q", f.st("hog.db_conns.st"))
	}
	f.pg = pgAnswer(8, "tando_hog 10 8")
	f.ticks(4)
	if st := f.st("hog.db_conns.st"); st != "pending" || len(f.sentBodies()) != 0 {
		t.Fatalf("after 4 samples at 8 of 10: %q, %d sent; want pending, 0", st, len(f.sentBodies()))
	}
	f.tick()
	if f.st("hog.db_conns.st") != "firing" || f.countSent(connsFiring) != 1 {
		t.Fatalf("not fired at the 5th sample: %q %v", f.st("hog.db_conns.st"), f.sentBodies())
	}
	if d := f.st("hog.db_conns.det"); !strings.HasPrefix(d, "8 of 10 database connections in use (the limit of its role tando_hog;") {
		t.Errorf("detail %q", d)
	}
	f.ticks(3)
	f.pg = pgAnswer(2, "tando_hog 10 2")
	f.tick()
	if f.st("hog.db_conns.st") != "firing" {
		t.Fatalf("resolved after one good sample")
	}
	f.tick()
	if f.countSent(`"state":"resolved","app":"hog","check":"db_conns"`) != 1 || len(f.sentBodies()) != 2 {
		t.Fatalf("not resolved once: %v", f.sentBodies())
	}
	// a short burst does not fire
	f.pg = pgAnswer(10, "tando_hog 10 10")
	f.ticks(3)
	f.pg = pgAnswer(2, "tando_hog 10 2")
	f.ticks(3)
	if n := len(f.sentBodies()); n != 2 {
		t.Errorf("a 3-minute burst sent something: %d messages", n)
	}
}

func TestDBConnsLimitIsTheServers(t *testing.T) {
	for _, tt := range []struct {
		name     string
		role     string
		settings []string
		fires    bool
	}{
		{"8 of the server's 10", "tando_hog 10 8", nil, true},
		{"8 of a limit raised to 20", "tando_hog 20 8", nil, false},
		{"16 of 20", "tando_hog 20 16", nil, true},
		{"a role without a limit", "tando_hog -1 15", nil, false},
		{"hog.db_conn_pct=50", "tando_hog 10 5", []string{"hog.db_conn_pct=50"}, true},
		{"hog.db_conns=off", "tando_hog 10 10", []string{"hog.db_conns=off"}, false},
		{"another app's role", "tando_other 10 10", nil, false},
	} {
		f := hostWithDB(t)
		f.settings(append([]string{"db_conn_for=1", "postgres=off"}, tt.settings...)...)
		f.pg = pgAnswer(3, tt.role)
		f.ticks(2)
		if got := f.st("hog.db_conns.st") == "firing"; got != tt.fires {
			t.Errorf("%s: firing=%v, want %v", tt.name, got, tt.fires)
		}
	}
}

func TestPostgresDownIsOneHostAlert(t *testing.T) {
	f := hostWithDB(t)
	f.pg = pgAnswer(9, "tando_hog 10 9")
	f.settings("db_conn_for=1")
	f.tick() // db_conns fires
	f.reset()
	f.pgErr = "psql: exit status 2: psql: error: connection to server on socket \"/var/run/postgresql/.s.PGSQL.5432\" failed: No such file or directory\n\tIs the server running locally and accepting connections on that socket?"
	f.tick()
	if st := f.st("_host.postgres.st"); st != "pending" || len(f.sentBodies()) != 0 {
		t.Fatalf("after one failed question: %q, %d sent (down_after=2)", st, len(f.sentBodies()))
	}
	f.tick()
	if f.st("_host.postgres.st") != "firing" || f.countSent(pgFiring) != 1 {
		t.Fatalf("not fired: %q %v", f.st("_host.postgres.st"), f.sentBodies())
	}
	want := `PostgreSQL does not answer (connection to server on socket "/var/run/postgresql/.s.PGSQL.5432" failed: No such file or directory); used by hog: sudo systemctl status postgresql`
	if d := f.st("_host.postgres.det"); d != want {
		t.Errorf("detail %q\nwant   %q", d, want)
	}
	f.ticks(3)
	// the app's connections are not judged while the server does not answer: no resolve, no repeat
	if f.st("hog.db_conns.st") != "firing" || len(f.sentBodies()) != 1 {
		t.Errorf("while down: db_conns %q, %d sent", f.st("hog.db_conns.st"), len(f.sentBodies()))
	}
	if vs := f.vstate(); vs["pgc.hog"] != "" || vs["pgsz.hog"] == "" {
		t.Errorf("while down the connections are unknown, the last size is kept: %v", vs)
	}
	f.pgErr, f.pg = "", pgAnswer(1, "tando_hog 10 1")
	f.ticks(2)
	if f.countSent(`"state":"resolved","app":"host","check":"postgres"`) != 1 || f.st("_host.postgres.st") != "ok" {
		t.Errorf("not resolved: %v", f.sentBodies())
	}
	// a timeout, and an answer that is not the server's, are no answer either
	for _, bad := range []string{"psql: timed out after 8s"} {
		f.pgErr = bad
		f.ticks(2)
		if !strings.Contains(f.st("_host.postgres.det"), "timed out after 8s") {
			t.Errorf("%s: detail %q", bad, f.st("_host.postgres.det"))
		}
	}
	// the last app with a database is removed: nothing needs the server, the alert resolves
	f.app("hog")
	f.ticks(2)
	if st := f.st("_host.postgres.st"); st == "firing" {
		t.Errorf("still firing with no app that has a database")
	}
	if vs := f.vstate(); vs["pgsz.hog"] != "" || vs["pgc.hog"] != "" || vs["pgl.hog"] != "" {
		t.Errorf("an app that no longer has a database keeps its numbers: %v", vs)
	}
}

func TestPostgresOffAndBootGrace(t *testing.T) {
	f := hostWithDB(t)
	f.pgErr = "psql: exit status 2"
	f.settings("postgres=off")
	f.ticks(3)
	if f.st("_host.postgres.st") != "" {
		t.Errorf("postgres=off: %q", f.st("_host.postgres.st"))
	}
	f = hostWithDB(t)
	f.pgErr = "psql: exit status 2"
	f.boot = f.now.Unix() - 20 // the host started 20 s ago: boot_grace
	f.write("proc/1/stat", "1 (systemd) S 0 1 1 0 -1 4194560 1 2 3 4 5 6 7 8 20 0 1 0 0 1 1\n")
	f.tick()
	f.tick()
	if f.st("_host.postgres.st") != "" {
		t.Errorf("judged within the boot grace: %q", f.st("_host.postgres.st"))
	}
}

func TestPostgresSlotsOfTheWholeServer(t *testing.T) {
	f := hostWithDB(t)
	f.pg = pgAnswer(14, "tando_hog 10 5") // 14 of 17 usable: 82%
	f.ticks(4)
	if st := f.st("_host.postgres.st"); st != "pending" {
		t.Fatalf("after 4 samples: %q", st)
	}
	f.tick()
	if f.countSent(pgFiring) != 1 || !strings.HasPrefix(f.st("_host.postgres.det"), "PostgreSQL: 14 of 17 connection slots in use (max_connections 20, 3 kept back)") {
		t.Fatalf("slots: %q %v", f.st("_host.postgres.det"), f.sentBodies())
	}
	if f.st("hog.db_conns.st") != "" {
		t.Errorf("hog (5 of 10) judged bad: %q", f.st("hog.db_conns.st"))
	}
	f.pg = pgAnswer(13, "tando_hog 10 5") // 76%
	f.ticks(2)
	if f.st("_host.postgres.st") != "ok" {
		t.Errorf("not resolved at 13 of 17")
	}
}

func TestParsePg(t *testing.T) {
	if f := parsePg([]byte("d|tando_a|100\nm|20|3|2|4\nr|tando_a|10|0|3\nr|tando_b_c|-1|0|0\n")); f == nil || f.max != 20 || f.reserved != 5 ||
		f.clients != 4 || f.roles["tando_a"] != (pgRole{10, 3}) || f.roles["tando_b_c"].limit != -1 || f.sizes["tando_a"] != 100 {
		t.Errorf("parsed %+v", f)
	}
	for _, s := range []string{"", "\n", "r|tando_a|10|0|3\n", "m|x|3|0|4\n", "m|20|3\n", "ERROR:  canceling statement\n", "d|tando_a|100\n"} {
		if f := parsePg([]byte(s)); f != nil {
			t.Errorf("%q read as an answer: %+v", s, f)
		}
	}
	if pgRoleOf("my-app-2") != "tando_my_app_2" {
		t.Errorf("role %q", pgRoleOf("my-app-2"))
	}
}

// The database counts as the app's disk use: files and database together against app_max_mb.
func TestDatabaseSizeCountsAsDiskUse(t *testing.T) {
	f := hostWithDB(t)
	f.write("opt/host.conf", "app_max_mb=1000\n")
	f.du = "300"
	f.pgSizes = "d|tando_hog|" + decimal.Itoa(600<<20) + "\n"
	f.ticks(2)
	if st := f.st("hog.disk.st"); st != "" {
		t.Fatalf("300 MB of files and 600 MB of database under 1000 MB: %q", st)
	}
	f.pgSizes = "d|tando_hog|" + decimal.Itoa(900<<20) + "\n"
	f.ticks(11) // (the size and the files are measured every disk_every minutes)
	want := "hog uses 1200 MB of disk (files 300 MB, database 900 MB), over the 1000 MB allowed per app (host setup app_max_mb=N)"
	if d := f.st("hog.disk.det"); d != want || f.st("hog.disk.st") != "firing" {
		t.Errorf("detail %q\nwant   %q (state %q)", d, want, f.st("hog.disk.st"))
	}
	if st := f.st("plain.disk.st"); st != "" {
		t.Errorf("an app without a database: %q", st)
	}
	if len(f.called("systemd-run")) != 0 {
		t.Errorf("the app was stopped: %v", f.called("systemd-run"))
	}
}

func TestPgRowsOfBriefAndHealth(t *testing.T) {
	f := hostWithDB(t)
	f.ticks(2)
	w := f.watch()
	o, _ := do(func(o *out.Writer) error { w.Brief(o, []string{"hog"}); return nil })
	if o != "pg\thog\t8388608\t2\t10\nbackupcfg\thog\t50\ton\n" {
		t.Errorf("brief hog: %q", o)
	}
	if o, _ := do(func(o *out.Writer) error { w.Brief(o, []string{"plain"}); return nil }); o != "backupcfg\tplain\t50\ton\n" {
		t.Errorf("brief of an app without a database: %q", o)
	}
	if o, _ := do(func(o *out.Writer) error { w.Brief(o, nil); return nil }); o != "" {
		t.Errorf("brief of every app: %q", o)
	}
	o, err := do(func(o *out.Writer) error { return w.Health(o, []string{"hog"}) })
	if err != nil || !strings.Contains(o, "\npg\thog\t8388608\t2\t10\n") {
		t.Errorf("health hog: %v %q", err, o)
	}
	f.jobRan("hog", "x", "failed", "exit-code", "1", "1", 5)
	f.app("hog", "database=postgres", "job.x=daily | false")
	f.tick()
	o, _ = do(func(o *out.Writer) error { return w.Health(o, []string{"hog"}) })
	if l, _, _ := strings.Cut(o, "\n"); !strings.HasSuffix(l, "\tjob.x") {
		t.Errorf("health's firing checks: %q", l)
	}
}
