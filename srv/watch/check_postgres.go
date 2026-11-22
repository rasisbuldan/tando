package watch

import (
	"os"
	"path/filepath"
	"strings"
	"time"

	"tando/srv/internal/bashread"
	"tando/srv/internal/decimal"
	"tando/srv/internal/run"
	"tando/srv/internal/valid"
)

// PostgreSQL, for the apps that have a database (database = postgres: one shared server, a role
// and a database tando_<app> each, the role limited to a number of connections by the agent).
// Asked once per run, and only when an app has a database: one psql as the postgres user over
// the local socket (the agent's own way in; a slot kept for the superuser, so it gets in when the
// apps have taken every other), with a connect timeout, a statement timeout and the run's own.
// Its answer feeds three checks:
//
//	host postgres   no answer (stopped, starting, refusing): the apps with a database are down
//	                with it; or the server's usable slots (max_connections less the reserved
//	                ones) are db_conn_pct full for db_conn_for samples
//	db_conns        per app: its role holds db_conn_pct of the role's connection limit (read from
//	                the server: pg_roles.rolconnlimit) for db_conn_for samples
//	disk            per app: the size of its database counts as the app's disk use (check_app.go)
//
// The sizes (pg_database_size stats every file of a database) are asked every 5 minutes (or
// disk_every, when shorter), the connections every run; the database's own numbers too
// (check_dbstats.go: same psql, before the connections). The last answer is kept in the volatile state for tando status and
// tando health: pgsz.<app> bytes, pgc.<app> connections, pgl.<app> the role's limit.

const (
	pgConnsSQL = `SELECT 'm', current_setting('max_connections'), current_setting('superuser_reserved_connections'), ` +
		`coalesce(current_setting('reserved_connections', true), '0'), ` +
		`(SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()) ` +
		`UNION ALL SELECT 'r', r.rolname, r.rolconnlimit::text, '0', ` +
		`(SELECT count(*) FROM pg_stat_activity a WHERE a.usename = r.rolname) FROM pg_roles r WHERE r.rolname LIKE 'tando\_%'`
	pgSizesSQL = `SELECT 'd', datname, pg_database_size(oid) FROM pg_database WHERE datname LIKE 'tando\_%'`
	pgTimeout  = 10 * time.Second // (8 s before the database's numbers: at most 4 x 500 ms more)
)

// pgEnv: psql gives up connecting after 3 s and the server ends a statement after 4 s.
var pgEnv = append(append([]string{}, cmdEnv...), "PGCONNECT_TIMEOUT=3", "PGOPTIONS=-c statement_timeout=4000", "PGAPPNAME=tando-watch")

// pgFacts is one answer of the server.
type pgFacts struct {
	max, reserved, clients int64 // max_connections; kept back for superusers and reserved roles; client sessions now
	roles                  map[string]pgRole
	sizes                  map[string]int64 // database -> bytes (only when asked)
	stats                  pgStats          // the database's numbers (check_dbstats.go)
}

type pgRole struct{ limit, conns int64 }

// pgRoleOf is the agent's db_role: the app's role and database.
func pgRoleOf(app string) string { return "tando_" + strings.ReplaceAll(app, "-", "_") }

// parsePg reads psql's unaligned rows; nil without the server's own row (no answer).
func parsePg(out []byte) *pgFacts {
	f := &pgFacts{roles: map[string]pgRole{}, sizes: map[string]int64{}, stats: newPgStats()}
	up := false
	for _, l := range bashread.Lines(out) {
		p := strings.Split(l, "|")
		switch {
		case len(p) == 5 && p[0] == "m":
			f.max, f.reserved, f.clients = num(p[1], 0), num(p[2], 0)+num(p[3], 0), num(p[4], 0)
			up = decimal.IsDigits(p[1])
		case len(p) == 5 && p[0] == "r":
			f.roles[p[1]] = pgRole{limit: num(p[2], -1), conns: num(p[4], 0)}
		case len(p) == 3 && p[0] == "d" && decimal.IsDigits(p[2]):
			f.sizes[p[1]] = num(p[2], 0)
		default:
			f.stats.row(p)
		}
	}
	if !up {
		return nil
	}
	return f
}

// checkPostgres asks the server (when an app has a database) and judges the server itself.
func checkPostgres(t *tick) {
	const k = "_host.postgres"
	var users []string
	// an app node linked to a data node: its apps' databases are there, and the data node's own
	// tandod watches them (docs/DATA-NODE.md); a data node watches its projects' (data/db/<app>)
	remote := t.host["db_host"] != ""
	if t.host["role"] == "data" {
		users = dataProjects(t.w.Env.Root)
	}
	for _, a := range t.names {
		if c, _ := t.w.Cache.load(filepath.Join(t.w.appDir(a), "app.conf")); c["database"] == "postgres" && !remote {
			users = append(users, a)
		} else {
			t.vs.del("pgsz."+a, "pgc."+a, "pgl."+a) // (it had a database once: nothing stale for tando status)
		}
	}
	if len(users) == 0 {
		if t.st.has(k + ".st") { // the last app with a database is gone: nothing needs the server
			t.sample(k, "_host", "postgres", ok, "", 1)
		}
		return
	}
	// the sizes every 5 minutes (or disk_every, when shorter): the database's size is charted
	every := min(t.cfg.num("disk_every", ""), 5)
	sizes := t.now-t.vs.n("pgszt", 0) >= every*60 || t.now < t.vs.n("pgszt", 0)
	// (the connections last: psql's exit status is its last command's; check_dbstats.go)
	// ver: the server's version as last seen (0: not known), pgss: pg_stat_statements readable then
	ver, pgss := t.vs.n("pgver", 0), t.vs.get("pgss") == "1"
	argv := []string{"psql", "-X", "-q", "-At"}
	if sizes {
		argv = append(argv, "--command="+pgSizesSQL)
	}
	argv = append(argv, "--command="+pgFastSQL, "--command="+pgVerSQL, "--command="+pgDBSQL)
	switch {
	case ver >= 170000:
		argv = append(argv, "--command="+pgCkpt17SQL)
	case ver >= 140000:
		argv = append(argv, "--command="+pgCkpt14SQL)
	case ver > 0:
		argv = append(argv, "--command="+pgCkpt10SQL)
	}
	if pgss && ver >= 130000 {
		argv = append(argv, "--command="+pgTop13SQL)
	} else if pgss && ver > 0 {
		argv = append(argv, "--command="+pgTop10SQL)
	}
	argv = append(argv, "--command="+pgSlowSQL, "--command="+pgConnsSQL)
	c := run.Cmd{Argv: argv, Env: pgEnv, Timeout: pgTimeout, User: "postgres"}
	out, err := t.w.Env.Run.Output(t.ctx, c)
	f := parsePg(out)
	on := t.cfg.on("postgres", "") && !t.holdAll // (not while the host boots: it starts with the apps)
	if err != nil || f == nil {
		for _, a := range users {
			t.vs.del("pgc."+a, "pgl."+a)
		}
		if on {
			t.sample(k, "_host", "postgres", bad, "PostgreSQL does not answer ("+pgWhy(err)+"); "+pgUsers(users)+
				": sudo systemctl status postgresql", t.cfg.num("down_after", ""))
		}
		return
	}
	t.pg = f
	if sizes {
		t.vs.set("pgszt", decimal.Itoa(t.now))
	}
	writeDBStats(t, f, users, sizes)
	for _, a := range users {
		role := pgRoleOf(a)
		if r, ok := f.roles[role]; ok {
			t.vs.set("pgc."+a, decimal.Itoa(r.conns))
			t.vs.set("pgl."+a, decimal.Itoa(r.limit))
		}
		if b, ok := f.sizes[role]; ok {
			t.vs.set("pgsz."+a, decimal.Itoa(b))
		}
	}
	if !on {
		return
	}
	usable := f.max - f.reserved
	if pct := t.cfg.num("db_conn_pct", ""); usable > 0 && f.clients*100 >= usable*pct {
		t.sample(k, "_host", "postgres", bad, "PostgreSQL: "+decimal.Itoa(f.clients)+" of "+decimal.Itoa(usable)+
			" connection slots in use (max_connections "+decimal.Itoa(f.max)+", "+decimal.Itoa(f.reserved)+
			" kept back): at "+decimal.Itoa(usable)+" every app's new connections are refused; "+pgUsers(users),
			t.cfg.num("db_conn_for", ""))
		return
	}
	t.sample(k, "_host", "postgres", ok, "", 1)
}

// dataProjects: the projects a data node holds, by app name (the agent's data-db records)
func dataProjects(root string) []string {
	es, _ := os.ReadDir(filepath.Join(root, "data", "db"))
	var r []string
	for _, e := range es {
		if n := e.Name(); e.Type().IsRegular() && valid.App(n) {
			r = append(r, n)
		}
	}
	return r
}

// pgWhy is psql's reason on one line, without its prefixes.
func pgWhy(err error) string {
	if err == nil {
		return "an answer that cannot be read"
	}
	s, _, _ := strings.Cut(err.Error(), "\n")
	if i := strings.Index(s, "error: "); i >= 0 {
		s = s[i+len("error: "):]
	}
	return cut(strings.TrimPrefix(s, "psql: "), 160)
}

// pgUsers names the apps that need the server (three, then a count).
func pgUsers(apps []string) string {
	if len(apps) > 3 {
		return "used by " + strings.Join(apps[:3], ", ") + " and " + decimal.Itoa(int64(len(apps)-3)) + " more"
	}
	return "used by " + strings.Join(apps, ", ")
}

// checkDBConns: the connections of the app's role against the role's limit, as the server gave
// both. At the limit PostgreSQL refuses the app's next connection (a pool larger than the limit,
// connections that are never given back, a second instance during a deploy). Not judged while
// the server does not answer (host postgres says that) or for a role without a limit.
func checkDBConns(t *tick, a *appTick) {
	if a.conf["database"] != "postgres" || t.pg == nil || !t.cfg.on("db_conns", a.name) {
		return
	}
	r, found := t.pg.roles[pgRoleOf(a.name)]
	if !found || r.limit <= 0 {
		return
	}
	k := a.key("db_conns")
	need := t.cfg.num("db_conn_for", a.name)
	if r.conns*100 < r.limit*t.cfg.num("db_conn_pct", a.name) {
		t.sample(k, a.name, "db_conns", ok, "", need)
		return
	}
	t.sample(k, a.name, "db_conns", bad, decimal.Itoa(r.conns)+" of "+decimal.Itoa(r.limit)+
		" database connections in use (the limit of its role "+pgRoleOf(a.name)+"; at "+decimal.Itoa(r.limit)+
		" PostgreSQL refuses the next one): make the app's connection pool smaller, or look for connections it never gives back", need)
}
