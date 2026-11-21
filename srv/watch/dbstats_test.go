package watch

import (
	"encoding/hex"
	"os"
	"slices"
	"strings"
	"testing"
	"time"

	"tando/srv/internal/decimal"
	"tando/srv/internal/pgstat"
)

// ---- the database's numbers in the one psql (check_dbstats.go) ----

// pgDBRow is psql's s row for tando_hog: commits, deadlocks and xid age given, the rest fixed.
func pgDBRow(commits, deadlocks, reset, xidAge int64) string {
	n := decimal.Itoa
	// commit rollback returned fetched inserted updated deleted hit read deadlocks tfiles tbytes conflicts
	// reset active idle idletx waiting xactage idletxage xidage
	return "s|tando_hog|" + n(commits) + "|3|1000|500|20|10|5|9900|100|" + n(deadlocks) + "|2|8192|0|" + n(reset) +
		"|1|4|1|0|7|42|" + n(xidAge) + "\n"
}

// pgVersion makes the fake server answer as PostgreSQL ver, with every statement of that version.
func pgVersion(f *fakeHost, ver string, pgss bool) {
	s := "0"
	if pgss {
		s = "1"
	}
	f.pgStat = map[string]string{
		pgVerSQL:    "v|" + ver + "|" + s + "\n",
		pgDBSQL:     pgDBRow(100, 0, 1_700_000_000, 1000),
		pgCkpt17SQL: "c|11|2|123456789\n",
		pgCkpt14SQL: "c|12|3|23456789\n",
		pgCkpt10SQL: "c|13|4|-\n",
	}
}

func dbLines(t *testing.T, f *fakeHost) []pgstat.Sample {
	t.Helper()
	b, _ := os.ReadFile(pgstat.File(f.path("lib/metrics"), "hog"))
	var r []pgstat.Sample
	for _, l := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		if s, ok := pgstat.Parse(l); ok {
			r = append(r, s)
		}
	}
	return r
}

func TestDBStatsPerVersion(t *testing.T) {
	for _, tt := range []struct {
		ver        string
		sql        string
		timed, wal int64
	}{
		{"140011", pgCkpt14SQL, 12, 23456789},
		{"160004", pgCkpt14SQL, 12, 23456789},
		{"170002", pgCkpt17SQL, 11, 123456789},
		{"130015", pgCkpt10SQL, 13, -1},
	} {
		f := hostWithDB(t)
		pgVersion(f, tt.ver, false)
		f.ticks(2)
		last := f.pgCmds[len(f.pgCmds)-1].Argv
		if !slices.Contains(last, "--command="+tt.sql) {
			t.Errorf("PG %s: the checkpoint statement of its version is not asked: %v", tt.ver, last)
		}
		for _, other := range []string{pgCkpt17SQL, pgCkpt14SQL, pgCkpt10SQL} {
			if other != tt.sql && slices.Contains(last, "--command="+other) {
				t.Errorf("PG %s: asked another version's statement %q", tt.ver, other)
			}
		}
		if first := f.pgCmds[0].Argv; slices.ContainsFunc(first, func(a string) bool { return strings.Contains(a, "pg_stat_bgwriter") || strings.Contains(a, "pg_stat_checkpointer") }) {
			t.Errorf("PG %s: the first run (version not known yet) asked a version-dependent statement", tt.ver)
		}
		l := dbLines(t, f)
		if len(l) != 2 {
			t.Fatalf("PG %s: %d lines in hog.db after 2 runs, want 2", tt.ver, len(l))
		}
		s := l[1]
		if s[pgstat.Ver] <= 0 || s[pgstat.MaxConn] != 20 || s[pgstat.Commit] != 100 || s[pgstat.Rollback] != 3 || s[pgstat.BlksHit] != 9900 ||
			s[pgstat.Active] != 1 || s[pgstat.Idle] != 4 || s[pgstat.IdleTx] != 1 || s[pgstat.XactAge] != 7 || s[pgstat.IdleTxAge] != 42 ||
			s[pgstat.XidAge] != 1000 || s[pgstat.StatsReset] != 1_700_000_000 || s[pgstat.CkptTimed] != tt.timed || s[pgstat.WalBytes] != tt.wal {
			t.Errorf("PG %s: line %v", tt.ver, s.Line())
		}
		if l[0][pgstat.Size] != 8388608 || l[1][pgstat.Size] != -1 {
			t.Errorf("PG %s: size measured at the first run only (every 5 min): %d, %d", tt.ver, l[0][pgstat.Size], l[1][pgstat.Size])
		}
		if fi, err := os.Stat(pgstat.File(f.path("lib/metrics"), "hog")); err != nil || fi.Mode().Perm() != 0o600 {
			t.Errorf("hog.db: %v %v", fi, err)
		}
		if _, err := os.Stat(pgstat.File(f.path("lib/metrics"), "plain")); err == nil {
			t.Errorf("an app without a database got a .db file")
		}
	}
}

// The new statements cannot make "PostgreSQL does not answer" fire: they come before the
// connections (psql's exit status is its last statement's), under a 500 ms statement timeout
// set just before them and 4000 again just after, and the run's timeout leaves room for them.
func TestDBStatsOrderAndTimeoutsKeepTheAnswerCheck(t *testing.T) {
	f := hostWithDB(t)
	pgVersion(f, "170002", true)
	f.ticks(2)
	for _, c := range f.pgCmds {
		a := c.Argv
		iFast, iVer, iSlow := slices.Index(a, "--command="+pgFastSQL), slices.Index(a, "--command="+pgVerSQL), slices.Index(a, "--command="+pgSlowSQL)
		if a[len(a)-1] != "--command="+pgConnsSQL || iSlow != len(a)-2 || iFast < 0 || iFast+1 != iVer || slices.Contains(a, "-v") ||
			c.Timeout > 10*time.Second || c.Timeout < 10*time.Second || pgFastSQL != "SET statement_timeout = 500" || pgSlowSQL != "SET statement_timeout = 4000" {
			t.Fatalf("order or timeouts: %v (timeout %v)", a, c.Timeout)
		}
		for _, x := range a[iFast+1 : iSlow] {
			if x == "--command="+pgSizesSQL || x == "--command="+pgConnsSQL {
				t.Fatalf("the sizes or the connections under the short timeout: %v", a)
			}
		}
	}
	// every new statement failing (no rows: errors go to stderr, the exit status is the last's)
	f.pgStat = map[string]string{}
	f.ticks(3)
	if st := f.st("_host.postgres.st"); st != "" && st != "ok" {
		t.Errorf("the new statements failing made the server look down: %q %q", st, f.st("_host.postgres.det"))
	}
	if vs := f.vstate(); vs["pgc.hog"] != "2" {
		t.Errorf("the connections are lost: %v", vs)
	}
	if n := len(dbLines(t, f)); n != 2 {
		t.Errorf("lines written without the database's rows: %d, want the 2 of before", n)
	}
	// and the version is still the last one known: the next runs still ask its statements
	if last := f.pgCmds[len(f.pgCmds)-1].Argv; !slices.Contains(last, "--command="+pgCkpt17SQL) {
		t.Errorf("the version was forgotten: %v", last)
	}
}

func TestDBStatsOnceAMinute(t *testing.T) {
	f := hostWithDB(t)
	f.settings("sample_seconds=0")
	pgVersion(f, "160004", false)
	f.tick()
	f.now = f.now.Add(-50 * time.Second) // (tick moved the clock a minute on)
	f.tick() // a second run 10 s later: re-evaluates, writes nothing
	if n := len(dbLines(t, f)); n != 1 {
		t.Errorf("%d lines from two runs 10 s apart, want 1", n)
	}
}

func TestDBDeadlockFiresOnANewOneAndResetsAreNotDeadlocks(t *testing.T) {
	f := hostWithDB(t)
	pgVersion(f, "160004", false)
	f.pgStat[pgDBSQL] = pgDBRow(100, 3, 1_700_000_000, 1000)
	f.ticks(3)
	if st := f.st("hog.db_deadlock.st"); st == "firing" || st == "pending" {
		t.Fatalf("3 old deadlocks (counted before tando looked) fired: %q", st)
	}
	f.pgStat[pgDBSQL] = pgDBRow(110, 4, 1_700_000_000, 1000)
	f.tick()
	if f.st("hog.db_deadlock.st") != "firing" || f.countSent(`"state":"firing","app":"hog","check":"db_deadlock"`) != 1 {
		t.Fatalf("a new deadlock did not fire: %q %v", f.st("hog.db_deadlock.st"), f.sentBodies())
	}
	if d := f.st("hog.db_deadlock.det"); !strings.HasPrefix(d, "1 deadlock(s) in its database tando_hog within a minute") {
		t.Errorf("detail %q", d)
	}
	f.ticks(10) // no new one: stays firing (deadlock_quiet 30), no repeat
	if f.st("hog.db_deadlock.st") != "firing" || len(f.sentBodies()) != 1 {
		t.Errorf("after 10 quiet minutes: %q, %d sent", f.st("hog.db_deadlock.st"), len(f.sentBodies()))
	}
	f.ticks(22)
	if f.countSent(`"state":"resolved","app":"hog","check":"db_deadlock"`) != 1 {
		t.Fatalf("not resolved after deadlock_quiet: %q %v", f.st("hog.db_deadlock.st"), f.sentBodies())
	}
	// a reset (pg_stat_reset, or a crash on PG <= 14): the counter goes down, then up from 0
	f.pgStat[pgDBSQL] = pgDBRow(5, 0, 1_800_000_500, 1000)
	f.tick()
	f.pgStat[pgDBSQL] = pgDBRow(9, 0, 1_800_000_500, 1000)
	f.tick()
	// the counter goes up while stats_reset changes in the same minute: a new base, not a deadlock
	f.pgStat[pgDBSQL] = pgDBRow(12, 2, 1_800_000_900, 1000)
	f.tick()
	if st := f.st("hog.db_deadlock.st"); st == "firing" || st == "pending" {
		t.Errorf("a reset fired db_deadlock: %q", st)
	}
	f.settings("hog.db_deadlock=off")
	f.pgStat[pgDBSQL] = pgDBRow(13, 5, 1_800_000_900, 1000)
	f.tick()
	if st := f.st("hog.db_deadlock.st"); st == "firing" || st == "pending" {
		t.Errorf("db_deadlock=off fired: %q", st)
	}
}

func TestDBWraparound(t *testing.T) {
	f := hostWithDB(t)
	pgVersion(f, "170002", false)
	f.pgStat[pgDBSQL] = pgDBRow(100, 0, 0, 200_000_000) // 9%: autovacuum's normal
	f.ticks(2)
	if f.st("hog.db_wrap.st") != "" || f.st("hog.db_wrap_warn.st") != "" {
		t.Fatalf("9%% judged bad")
	}
	f.pgStat[pgDBSQL] = pgDBRow(100, 0, 0, 600_000_000) // 27%
	f.tick()
	if f.st("hog.db_wrap_warn.st") != "firing" || f.st("hog.db_wrap.st") == "firing" {
		t.Fatalf("27%%: warn %q, wrap %q", f.st("hog.db_wrap_warn.st"), f.st("hog.db_wrap.st"))
	}
	if !lowSeverity("db_wrap_warn") || lowSeverity("db_wrap") {
		t.Errorf("severity: the warning is low, the 50%% one is not")
	}
	if d := f.st("hog.db_wrap_warn.det"); !strings.HasPrefix(d, "its database tando_hog has used 27% of its transaction IDs (age 600000000 of 2147483648)") {
		t.Errorf("detail %q", d)
	}
	f.pgStat[pgDBSQL] = pgDBRow(100, 0, 0, 1_200_000_000) // 55%
	f.ticks(3)
	if f.st("hog.db_wrap.st") != "firing" || f.st("hog.db_wrap_warn.st") != "ok" {
		t.Errorf("55%%: wrap %q, warn %q (resolved: the higher one fires)", f.st("hog.db_wrap.st"), f.st("hog.db_wrap_warn.st"))
	}
}

// pg_stat_statements: asked only when the server says it is created and preloaded (tando host
// setup --pg-stat-statements; never installed by the checks), and its text only in <app>.dbtop.
func TestDBTopOnlyWhenPgStatStatementsIsOn(t *testing.T) {
	top := "q|tando_hog|120|5300|44166|360|" + hex.EncodeToString([]byte("SELECT *\n FROM orders\tWHERE id = $1 AND note = 'a|b'")) + "\n" +
		"q|tando_other|1|1|1|1|" + hex.EncodeToString([]byte("SELECT 1")) + "\n"
	f := hostWithDB(t)
	pgVersion(f, "170002", false)
	f.pgStat[pgTop13SQL] = top
	f.ticks(3)
	for _, c := range f.pgCmds {
		if slices.ContainsFunc(c.Argv, func(a string) bool { return strings.Contains(a, "pg_stat_statements") && !strings.Contains(a, "'v'") }) {
			t.Fatalf("pg_stat_statements asked while it is off: %v", c.Argv)
		}
	}
	dir := f.path("lib/metrics")
	if _, err := os.Stat(pgstat.TopFile(dir, "hog")); err == nil {
		t.Fatalf("a top file without pg_stat_statements")
	}
	pgVersion(f, "170002", true)
	f.pgStat[pgTop13SQL] = top
	f.ticks(2)
	if !slices.Contains(f.pgCmds[len(f.pgCmds)-1].Argv, "--command="+pgTop13SQL) {
		t.Fatalf("on: not asked")
	}
	b, err := os.ReadFile(pgstat.TopFile(dir, "hog"))
	fi, _ := os.Stat(pgstat.TopFile(dir, "hog"))
	if err != nil || fi.Mode().Perm() != 0o600 || !strings.Contains(string(b), "q\t120\t5300\t44166\t360\tSELECT * FROM orders WHERE id = $1 AND note = 'a|b'\n") ||
		strings.Contains(string(b), "SELECT 1") {
		t.Fatalf("hog.dbtop: %v %q", err, b)
	}
	if h, _ := os.ReadFile(pgstat.File(dir, "hog")); strings.Contains(string(h), "orders") {
		t.Errorf("statement text in the history: %q", h)
	}
	// PG 12: the older column names
	f = hostWithDB(t)
	pgVersion(f, "120020", true)
	f.ticks(2)
	if last := f.pgCmds[len(f.pgCmds)-1].Argv; !slices.Contains(last, "--command="+pgTop10SQL) || slices.Contains(last, "--command="+pgTop13SQL) {
		t.Errorf("PG 12: %v", last)
	}
	// turned off again (the extension dropped): the file goes
	f = hostWithDB(t)
	pgVersion(f, "170002", true)
	f.pgStat[pgTop13SQL] = top
	f.ticks(2)
	pgVersion(f, "170002", false)
	f.ticks(2)
	if _, err := os.Stat(pgstat.TopFile(f.path("lib/metrics"), "hog")); err == nil {
		t.Errorf("the top file stays after pg_stat_statements went")
	}
}
