package watch

import (
	"encoding/hex"
	"path/filepath"

	"tando/srv/internal/decimal"
	"tando/srv/internal/pgstat"
)

// The database's own numbers, like a cloud console's (Cloud SQL, RDS): asked in the SAME psql as
// the connections (check_postgres.go), never a connection of their own, and written per app to
// <app>.db in the metrics directory (internal/pgstat). Two alerts judge them: db_deadlock and the
// wraparound pair db_wrap / db_wrap_warn. Idle in transaction is shown, never alerted: every
// app's role ends such a session after 5 minutes (db_idle_tx_timeout).
//
// They must never make the server look down. The psql's exit status is its last command's, and
// "PostgreSQL does not answer" fires on a failed or timed-out psql, so:
//   - the statements run before the connections statement, which stays the last;
//   - each runs under a statement_timeout of 500 ms (set just before them, and 4000 again just
//     after), so all of them together add at most 2 s to the run's 10 s;
//   - one that fails (a view this version lacks, pg_stat_statements not loaded) only loses its
//     rows: there is no ON_ERROR_STOP, and the rows are read by their first field.
//
// The variant of a version-dependent statement is chosen by server_version_num, which the 'v'
// row gives every run and the volatile state keeps for the next one (the first run after a start
// has no checkpoint, WAL or top-statement rows). psql runs as the postgres user over the socket:
// a superuser, which reads every session's and every statement's details; no pg_monitor grant
// is needed.
const (
	pgFastSQL = `SET statement_timeout = 500`
	pgSlowSQL = `SET statement_timeout = 4000` // (back to pgEnv's, for the connections)
	// v: the version, and whether pg_stat_statements can be read (created here and preloaded)
	pgVerSQL = `SELECT 'v', current_setting('server_version_num'), CASE WHEN current_setting('shared_preload_libraries') ` +
		`LIKE '%pg_stat_statements%' AND EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN 1 ELSE 0 END`
	// s: per database of an app: pg_stat_database's counters (stable since PG 9.2), its sessions by
	// state, the oldest transaction (pg_dump's and ours left out) and idle-in-transaction, and
	// age(datfrozenxid)
	pgDBSQL = `SELECT 's', d.datname, d.xact_commit, d.xact_rollback, d.tup_returned, d.tup_fetched, d.tup_inserted, ` +
		`d.tup_updated, d.tup_deleted, d.blks_hit, d.blks_read, d.deadlocks, d.temp_files, d.temp_bytes, d.conflicts, ` +
		`coalesce(extract(epoch FROM d.stats_reset)::bigint, 0), coalesce(a.act, 0), coalesce(a.idl, 0), coalesce(a.itx, 0), ` +
		`coalesce(a.wai, 0), coalesce(a.xage, 0), coalesce(a.iage, 0), age(b.datfrozenxid) ` +
		`FROM pg_stat_database d JOIN pg_database b ON b.oid = d.datid LEFT JOIN (SELECT datid, ` +
		`count(*) FILTER (WHERE state = 'active') AS act, count(*) FILTER (WHERE state = 'idle') AS idl, ` +
		`count(*) FILTER (WHERE state LIKE 'idle in transaction%') AS itx, count(*) FILTER (WHERE wait_event_type = 'Lock') AS wai, ` +
		`extract(epoch FROM max(now() - xact_start) FILTER (WHERE state <> 'idle' AND application_name NOT IN ('pg_dump', 'tando-watch')))::bigint AS xage, ` +
		`extract(epoch FROM max(now() - state_change) FILTER (WHERE state LIKE 'idle in transaction%'))::bigint AS iage ` +
		`FROM pg_stat_activity WHERE backend_type = 'client backend' GROUP BY datid) a ON a.datid = d.datid ` +
		`WHERE d.datname LIKE 'tando\_%'`
	// c: the cluster's checkpoints (timed, requested) and WAL bytes; where they live by version
	pgCkpt17SQL = `SELECT 'c', c.num_timed, c.num_requested, w.wal_bytes FROM pg_stat_checkpointer c, pg_stat_wal w`
	pgCkpt14SQL = `SELECT 'c', b.checkpoints_timed, b.checkpoints_req, w.wal_bytes FROM pg_stat_bgwriter b, pg_stat_wal w`
	pgCkpt10SQL = `SELECT 'c', checkpoints_timed, checkpoints_req, '-' FROM pg_stat_bgwriter`
	// q: the 10 statements of each app's database with the most total time (PG 13 renamed the
	// columns). Normalized by pg_stat_statements: constants are $1, $2, never values. The text,
	// cut to 500 characters, comes hex-encoded: it can hold "|" and newlines.
	pgTop13SQL = `SELECT 'q', d.datname, s.calls, round(s.tot)::bigint, round(s.mean * 1000)::bigint, s.rows, ` +
		`encode(convert_to(left(s.query, 500), 'UTF8'), 'hex') FROM (SELECT dbid, calls, total_exec_time AS tot, ` +
		`mean_exec_time AS mean, rows, query, row_number() OVER (PARTITION BY dbid ORDER BY total_exec_time DESC) AS n ` +
		`FROM pg_stat_statements) s JOIN pg_database d ON d.oid = s.dbid WHERE d.datname LIKE 'tando\_%' AND s.n <= 10 ORDER BY d.datname, s.n`
	pgTop10SQL = `SELECT 'q', d.datname, s.calls, round(s.tot)::bigint, round(s.mean * 1000)::bigint, s.rows, ` +
		`encode(convert_to(left(s.query, 500), 'UTF8'), 'hex') FROM (SELECT dbid, calls, total_time AS tot, ` +
		`mean_time AS mean, rows, query, row_number() OVER (PARTITION BY dbid ORDER BY total_time DESC) AS n ` +
		`FROM pg_stat_statements) s JOIN pg_database d ON d.oid = s.dbid WHERE d.datname LIKE 'tando\_%' AND s.n <= 10 ORDER BY d.datname, s.n`
)

// pgStats are the database rows of an answer.
type pgStats struct {
	ver     int64 // server_version_num (0: no v row)
	pgss    bool
	dbs     map[string]pgstat.Sample // database -> its columns of this minute (no time yet)
	cluster [3]int64                 // checkpoints timed, requested, WAL bytes (-1: not known)
	top     map[string][]pgstat.Query
}

func newPgStats() pgStats {
	return pgStats{dbs: map[string]pgstat.Sample{}, cluster: [3]int64{-1, -1, -1}, top: map[string][]pgstat.Query{}}
}

// pgStatCols: the s row's fields after the name, in order, and their columns.
var pgStatCols = []int{pgstat.Commit, pgstat.Rollback, pgstat.Returned, pgstat.Fetched, pgstat.Inserted, pgstat.Updated,
	pgstat.Deleted, pgstat.BlksHit, pgstat.BlksRead, pgstat.Deadlocks, pgstat.TempFiles, pgstat.TempBytes, pgstat.Conflicts,
	pgstat.StatsReset, pgstat.Active, pgstat.Idle, pgstat.IdleTx, pgstat.Waiting, pgstat.XactAge, pgstat.IdleTxAge, pgstat.XidAge}

// row reads one of the database rows (v, s, c, q); false when p is none of them.
func (s *pgStats) row(p []string) bool {
	switch {
	case len(p) == 3 && p[0] == "v":
		s.ver, s.pgss = num(p[1], 0), p[2] == "1"
	case len(p) == 2+len(pgStatCols) && p[0] == "s":
		x := pgstat.Empty()
		for i, c := range pgStatCols {
			x[c] = cnum(p[2+i])
		}
		s.dbs[p[1]] = x
	case len(p) == 4 && p[0] == "c":
		s.cluster = [3]int64{cnum(p[1]), cnum(p[2]), cnum(p[3])}
	case len(p) == 7 && p[0] == "q":
		b, err := hex.DecodeString(p[6])
		if err != nil || len(s.top[p[1]]) >= 10 {
			return true
		}
		s.top[p[1]] = append(s.top[p[1]], pgstat.Query{Calls: cnum(p[2]), TotalMs: cnum(p[3]), MeanUs: cnum(p[4]), Rows: cnum(p[5]), Text: string(b)})
	default:
		return false
	}
	return true
}

// cnum: a counter or gauge; -1 when it is not a number (not known).
func cnum(s string) int64 {
	if !decimal.IsDigits(s) {
		return -1
	}
	return num(s, -1)
}

// metricsDir is where tando-metrics keeps its files (and <app>.db).
func (w Watch) metricsDir() string { return filepath.Join(w.Env.Lib, "metrics") }

// writeDBStats appends this minute's line for each app with a database, and its top statements
// (or removes them: pg_stat_statements off). Once a minute: a second run in it writes nothing.
func writeDBStats(t *tick, f *pgFacts, users []string, sizes bool) {
	s := f.stats
	if s.ver > 0 {
		t.vs.set("pgver", decimal.Itoa(s.ver))
	}
	if s.pgss {
		t.vs.set("pgss", "1")
	} else {
		t.vs.del("pgss")
	}
	if last := t.vs.n("pgdbt", 0); last > 0 && t.now >= last && t.now-last < 50 {
		return
	}
	t.vs.set("pgdbt", decimal.Itoa(t.now))
	dir := t.w.metricsDir()
	for _, a := range users {
		db := pgRoleOf(a)
		x, ok := s.dbs[db]
		if !ok {
			continue
		}
		x[pgstat.T], x[pgstat.Ver], x[pgstat.MaxConn] = t.now, s.ver, f.max
		if s.ver <= 0 {
			x[pgstat.Ver] = -1
		}
		if b, ok := f.sizes[db]; ok && sizes {
			x[pgstat.Size] = b
		}
		x[pgstat.CkptTimed], x[pgstat.CkptReq], x[pgstat.WalBytes] = s.cluster[0], s.cluster[1], s.cluster[2]
		pgstat.Append(dir, a, x) // (a full disk: a gap, and the disk alert says why)
		var top []pgstat.Query
		if s.pgss {
			top = s.top[db]
		}
		pgstat.WriteTop(dir, a, t.now, top)
	}
}

// checkDBStats judges the app's database from this run's answer: a new deadlock, and how close
// its transaction IDs are to wraparound. Not judged while the server does not answer.
func checkDBStats(t *tick, a *appTick) {
	if a.conf["database"] != "postgres" || t.pg == nil {
		return
	}
	x, found := t.pg.stats.dbs[pgRoleOf(a.name)]
	if !found {
		return
	}
	checkDeadlocks(t, a, x)
	checkWraparound(t, a, x[pgstat.XidAge])
}

// checkDeadlocks: PostgreSQL broke a deadlock in the app's database (it ended one of the
// transactions with an error the app saw). Fires on any new one, then stays firing until
// deadlock_quiet minutes pass without another (as oom: a count that rises, not a level).
// A counter that went down or a new stats_reset is a reset: no deadlock, a new base.
func checkDeadlocks(t *tick, a *appTick, x pgstat.Sample) {
	n, reset := x[pgstat.Deadlocks], x[pgstat.StatsReset]
	if n < 0 {
		return
	}
	k := a.key("db_deadlock")
	prev, prevReset := t.vs.n("pgdl."+a.name, -1), t.vs.n("pgdr."+a.name, -1)
	t.vs.set("pgdl."+a.name, decimal.Itoa(n))
	t.vs.set("pgdr."+a.name, decimal.Itoa(reset))
	if !t.cfg.on("db_deadlock", a.name) {
		t.st.del(a.name+".dl_t", a.name+".dl_n")
		t.sample(k, a.name, "db_deadlock", ok, "", 1)
		return
	}
	if prev >= 0 && n > prev && reset == prevReset {
		t.st.set(a.name+".dl_t", decimal.Itoa(t.now))
		t.st.set(a.name+".dl_n", decimal.Itoa(n-prev))
	}
	q := t.cfg.num("deadlock_quiet", a.name)
	if t.st.get(a.name+".dl_t") != "" && t.now-t.st.n(a.name+".dl_t", 0) < q*60 {
		t.sample(k, a.name, "db_deadlock", bad, t.st.get(a.name+".dl_n")+" deadlock(s) in its database "+pgRoleOf(a.name)+
			" within a minute: PostgreSQL cancelled one transaction of each, the app got an error. Look for transactions that "+
			"lock the same rows in a different order; the PostgreSQL log names the statements (/var/log/postgresql)", 1)
		return
	}
	t.sample(k, a.name, "db_deadlock", ok, "", 1)
	t.st.del(a.name+".dl_t", a.name+".dl_n")
}

// checkWraparound: transaction IDs of the database used towards the 2^31 at which PostgreSQL
// stops writing: db_wrap at db_wrap_pct (50), db_wrap_warn (low severity) from db_wrap_warn_pct
// (25) up to it. Autovacuum freezes a database at 200 million (9%): far past that, it cannot.
func checkWraparound(t *tick, a *appTick, age int64) {
	if age < 0 {
		return
	}
	pct := age * 100 / pgstat.Wraparound
	crit, warn := t.cfg.num("db_wrap_pct", a.name), t.cfg.num("db_wrap_warn_pct", a.name)
	det := "its database " + pgRoleOf(a.name) + " has used " + decimal.Itoa(pct) + "% of its transaction IDs (age " +
		decimal.Itoa(age) + " of 2147483648); at 100% PostgreSQL stops accepting writes. Autovacuum is not freezing it: " +
		"look for a transaction left open for a long time, then run VACUUM (FREEZE) in it (tando db psql " + a.name + ")"
	if t.cfg.on("db_wrap", a.name) {
		r := ok
		if pct >= crit {
			r = bad
		}
		t.sample(a.key("db_wrap"), a.name, "db_wrap", r, det, 1)
	}
	if t.cfg.on("db_wrap_warn", a.name) {
		r := ok
		if pct >= warn && pct < crit {
			r = bad
		}
		t.sample(a.key("db_wrap_warn"), a.name, "db_wrap_warn", r, det, 1)
	}
}
