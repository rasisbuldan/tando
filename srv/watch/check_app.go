package watch

import (
	"path/filepath"
	"strings"
	"time"

	"tando/srv/internal/bashread"
	"tando/srv/internal/decimal"
	"tando/srv/internal/fsinfo"
	"tando/srv/internal/kvfile"
	"tando/srv/internal/run"
)

// checkMemory: anon + shmem against the unit's MemoryMax, sustained for mem_for samples.
func checkMemory(t *tick, a *appTick) {
	max := a.unit["MemoryMax"]
	if !t.cfg.on("memory", a.name) || !decimal.IsDigits(max) || num(max, 0) <= 0 || a.hold {
		return
	}
	k := a.key("memory")
	mx := num(max, 0)
	cg := t.w.appCgroup(a.name)
	mem := memstat(cg)
	mp, mf := t.cfg.num("mem_pct", a.name), t.cfg.num("mem_for", a.name)
	if mem*100 < mx*mp {
		t.sample(k, a.name, "memory", ok, "", mf)
		return
	}
	sw := num(strings.TrimSpace(readFirst(filepath.Join(cg, "memory.swap.current"))), 0)
	det := "memory " + decimal.Itoa(mem>>20) + " MB of " + decimal.Itoa(mx>>20) + " MB (" + decimal.Itoa(mem*100/mx) + "%)"
	if sw > 1048576 {
		det += ", " + decimal.Itoa(sw>>20) + " MB more in swap"
	}
	t.sample(k, a.name, "memory", bad, det, mf)
}

// checkBackup: apps with daily backups; the last one older than backup_hours fires. An app
// without any backup yet counts from its creation.
func checkBackup(t *tick, a *appTick) {
	if !t.cfg.on("backup", a.name) {
		return
	}
	checkOffsite(t, a)
	checkDrill(t, a)
	if or(a.conf["backup"], "off") != "daily" {
		return
	}
	k := a.key("backup")
	bh := t.cfg.num("backup_hours", a.name)
	last := a.state["last_backup"]
	switch {
	case decimal.IsDigits(last):
		if t.now-num(last, 0) > bh*3600 {
			t.sample(k, a.name, "backup", bad, "last backup "+dur(t.now-num(last, 0))+" ago", 1)
		} else {
			t.sample(k, a.name, "backup", ok, "", 1)
		}
	case decimal.IsDigits(a.conf["created"]) && t.now-num(a.conf["created"], 0) > bh*3600:
		t.sample(k, a.name, "backup", bad, "no backup recorded since the app was created "+dur(t.now-num(a.conf["created"], 0))+" ago", 1)
	}
}

// checkDrill: the last restore drill of the app (tando backup drill; the host runs one a month). A
// failed drill fires "drill" with the reason the agent recorded, and the next one that works
// resolves it. An app that never had a drill, or one with backups off, is not judged.
func checkDrill(t *tick, a *appTick) {
	if a.state["drill_result"] == "" {
		return
	}
	k := a.key("drill")
	if a.state["drill_result"] == "fail" && or(a.conf["backup"], "off") == "daily" {
		t.sample(k, a.name, "drill", bad, "the restore drill of the last backup failed: "+or(a.state["drill_why"], "no reason recorded"), 1)
		return
	}
	t.sample(k, a.name, "drill", ok, "", 1)
}

// checkOffsite: the app's backups in the offsite bucket, from the state file tando-offsite keeps
// (docs/BACKUP.md). Bad while the bucket's credentials fail, or while a backup has waited longer
// than alert_hours to be copied. No file, or offsite off for the app: nothing is judged, and an
// alert that was firing resolves.
func checkOffsite(t *tick, a *appTick) {
	ob, err := kvfile.Load(filepath.Join(t.w.Env.Lib, "offsite", "state", a.name))
	k := a.key("offsite")
	if err != nil {
		return
	}
	if ob["enabled"] != "1" {
		if t.st.or(k+".st", "ok") != "ok" { // turned off while firing: resolve, do not stay stuck
			t.sample(k, a.name, "offsite", ok, "", 1)
		}
		return
	}
	ah, op := num(or(ob["alert_hours"], "6"), 6), num(ob["oldest_pending"], 0)
	switch {
	case ob["creds"] == "failing":
		t.sample(k, a.name, "offsite", bad, "offsite credentials fail: "+ob["creds_error"], 1)
	case op > 0 && t.now-op > ah*3600:
		t.sample(k, a.name, "offsite", bad, "backup "+ob["oldest_pending_id"]+" not offsite after "+dur(t.now-op), 1)
	default:
		t.sample(k, a.name, "offsite", ok, "", 1)
	}
}

// checkAppDisk: the app's own files (shared/, data_dir, releases, incoming, assets) and its PostgreSQL
// database against app_max_mb, the files measured every disk_every minutes (du as root, one file
// system, no links followed), the database as the server last gave its size. Over the
// cap: an alert. Over it while its file system is disk_stop_pct full: the app is stopped (503
// page; tando start brings it back), so one app cannot take every other app's writes and deploys.
func checkAppDisk(t *tick, a *appTick) {
	if !t.cfg.on("disk", a.name) || t.now-t.vs.n("du."+a.name, 0) < t.cfg.num("disk_every", a.name)*60 {
		return
	}
	t.vs.set("du."+a.name, decimal.Itoa(t.now))
	d := t.w.appDir(a.name)
	var dirs []string
	// (assets: the shared fingerprinted files a pruned release keeps for its skew window; du counts
	// a file hard-linked from a kept release once)
	for _, f := range []string{filepath.Join(d, "shared"), filepath.Join(d, "releases"), filepath.Join(d, "incoming"), filepath.Join(d, "assets"), a.conf["data_dir"]} {
		if fsinfo.DirNoFollow(f) { // (data_dir is the app's choice: never a link)
			dirs = append(dirs, f)
		}
	}
	if len(dirs) == 0 {
		return // (du without a directory would measure the working directory: /)
	}
	out, _ := t.w.Env.Run.Output(t.ctx, run.Cmd{Argv: append([]string{"du", "-smxc", "--"}, dirs...), Env: cmdEnv, Timeout: 50 * time.Second})
	ls := bashread.Lines(out)
	if len(ls) == 0 {
		return
	}
	mb, _, _ := strings.Cut(ls[len(ls)-1], "\t")
	if !decimal.IsDigits(mb) {
		return
	}
	t.vs.set("dumb."+a.name, mb)
	k := a.key("disk")
	limit, setting := appDiskLimit(t.host, a.conf)
	// its database is its disk use too (the size PostgreSQL last gave, check_postgres.go)
	files, db := num(mb, 0), int64(0)
	if a.conf["database"] == "postgres" {
		db = t.vs.n("pgsz."+a.name, 0) >> 20
	}
	use := a.name + " uses " + decimal.Itoa(files+db) + " MB of disk"
	if db > 0 {
		use += " (files " + mb + " MB, database " + decimal.Itoa(db) + " MB)"
	}
	// disk_warn (low): from disk_warn_pct (80) of its share up to the share itself
	if t.cfg.on("disk_warn", a.name) {
		r, wp := ok, t.cfg.num("disk_warn_pct", a.name)
		if wp > 0 && (files+db)*100 >= limit*wp && files+db <= limit {
			r = bad
		}
		t.sample(a.key("disk_warn"), a.name, "disk_warn", r, use+", "+decimal.Itoa((files+db)*100/limit)+"% of the "+decimal.Itoa(limit)+" MB allowed ("+setting+")", 1)
	}
	if files+db <= limit {
		t.sample(k, a.name, "disk", ok, "", 1)
		return
	}
	det := use + ", over the " + decimal.Itoa(limit) + " MB allowed"
	if setting == "disk" {
		det += " to it (disk in tando.conf)"
	} else {
		det += " per app (host setup app_max_mb=N)"
	}
	var fsp int64
	mounts := t.w.mounts()
	shared, isFS := t.w.df(filepath.Join(d, "shared"), mounts)
	if isFS {
		fsp = num(shared.pct, 0)
	}
	// the guard stops an app to keep its file system from filling: the database counts for it
	// only when PostgreSQL keeps its data on that file system
	guard := files
	if pg, ok := t.w.df(t.w.PgData, mounts); db > 0 && ok && isFS && pg.target == shared.target {
		guard += db
	}
	sp := t.cfg.num("disk_stop_pct", a.name)
	if sp > 0 && guard > limit && fsp >= sp && a.hasUnit && !a.stopped && t.w.agentOutside(t.ctx, "stop", a.name, "stop "+a.name+" (its file system is full)", 120*time.Second) {
		det += "; its file system is " + decimal.Itoa(fsp) + "% full: " + a.name + " was stopped (free space, then tando start -a " + a.name + ")"
	}
	t.sample(k, a.name, "disk", bad, det, 1)
}

// appDiskLimit: the MB of disk an app may use, and where that comes from: its own disk = (tando.conf,
// like 2G or 500M), else the host's app_max_mb (8192).
func appDiskLimit(host, conf map[string]string) (int64, string) {
	if v := conf["disk"]; len(v) > 1 && decimal.IsDigits(v[:len(v)-1]) {
		n := num(v[:len(v)-1], 0)
		switch v[len(v)-1] {
		case 'G':
			n *= 1024
		case 'M':
		default:
			n = 0
		}
		if n > 0 {
			return n, "disk"
		}
	}
	return num(host["app_max_mb"], 8192), "app_max_mb"
}

// classify is what this minute was for the app in its uptime record (a probe below may refine
// "ok" with its class and time).
func classify(t *tick, a *appTick) {
	switch {
	case a.stopped:
		a.class = "stopped"
	case a.down == "bad":
		a.class = "down"
	case a.hold:
		a.class = "hold"
	default:
		a.class = "ok"
	}
}
