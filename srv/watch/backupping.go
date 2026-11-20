package watch

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"regexp"

	"tando/srv/internal/apps"
	"tando/srv/internal/atomicfile"
	"tando/srv/internal/decimal"
	"tando/srv/internal/fsinfo"
	"tando/srv/internal/out"
)

// The backup ping: an outside "dead man's switch" for the backups (docs/MONITORING.md, "From
// outside"). A URL the owner gives (a secret, like the heartbeat's: $SEC/backup-ping, root 600) is
// requested once per run of the daily backups, and only when the run was whole: every app with
// daily backups made one since the last ping, none failed, and with offsite copies on each of
// them is in the bucket. A failure sends nothing: the outside service notices the silence.
//
// The agent records per app, in its state file, how its daily backup went (cmd_backup_run):
//
//	backup_daily_ok=<epoch>  backup_daily_id=<backup id>  backup_daily_failed=<epoch>
//
// and this file judges them in the minute's delivery, outside the backup itself: a slow or dead
// receiver cannot delay or fail a backup. State (the run's state file): _bp.upto (the newest
// daily backup the last ping covered), _bp.ok (when it was sent), _bp.err and _bp.why (a failed
// request, retried after 5 minutes).

// backupPingName marks the backup ping among a run's deliveries (no notifier can have this name).
const backupPingName = "_backup"

var dailyIDRe = regexp.MustCompile(`^[0-9]{8}-[0-9]{6}-daily$`)

func (w Watch) backupPingFile() string { return filepath.Join(w.Sec, "backup-ping") }

// backupRun judges the daily backups against upto, the newest one the last ping covered: due
// when every app with daily backups has a newer one that succeeded (and is offsite, when offsite
// copies are on); newest is then the time the next ping covers. why says what is missing; it is
// empty when nothing happened since the last ping.
func (w Watch) backupRun(upto int64) (due bool, newest int64, why string) {
	names, _ := apps.Names(w.Env.Root)
	offsite := fsinfo.RegularFollow(filepath.Join(w.Env.Root, "offsite.conf"))
	var daily, fresh int
	var failed, waiting string
	for _, a := range names {
		if loadQuiet(filepath.Join(w.appDir(a), "app.conf"))["backup"] != "daily" {
			continue
		}
		daily++
		st := loadQuiet(filepath.Join(w.appDir(a), "state"))
		ok, bad := num(st["backup_daily_ok"], 0), num(st["backup_daily_failed"], 0)
		switch {
		case bad > ok:
			if failed == "" {
				failed = "the last daily backup of " + a + " failed"
			}
		case ok <= upto:
			if waiting == "" {
				waiting = "waiting for the next daily backup of " + a
			}
		case offsite && !w.backupOffsite(a, st["backup_daily_id"]):
			fresh++
			if failed == "" {
				failed = "the daily backup of " + a + " is not offsite yet"
			}
		default:
			fresh++
			newest = max(newest, ok)
		}
	}
	switch {
	case daily == 0:
		return false, 0, "no app has daily backups"
	case failed != "":
		return false, 0, failed
	case fresh == 0 && upto > 0:
		return false, 0, "" // nothing new since the last ping
	case waiting != "":
		return false, 0, waiting
	}
	return true, newest, ""
}

// backupOffsite: tando-offsite says this backup reached the bucket (the state file next to it)
func (w Watch) backupOffsite(app, id string) bool {
	if !dailyIDRe.MatchString(id) {
		return false
	}
	return loadQuiet(filepath.Join(w.Backups, app, id, "offsite"))["state"] == "uploaded"
}

// backupPingDue: the URL to request in this run, and what the ping covers; "" when none is set,
// nothing is due, or a failed request is waiting for its retry.
func (w Watch) backupPingDue(st *store, now int64) (string, int64) {
	f := w.backupPingFile()
	if !fsinfo.RegularFollow(f) {
		return "", 0
	}
	if e := st.n("_bp.err", 0); e > 0 && now >= e && now-e < 295 {
		return "", 0
	}
	due, newest, _ := w.backupRun(st.n("_bp.upto", 0))
	if !due {
		return "", 0
	}
	return loadQuiet(f)["url"], newest
}

// recordBackupPing writes a ping's outcome into the state.
func recordBackupPing(st *store, r deliverResult, now int64) {
	if r.ok {
		st.set("_bp.ok", decimal.Itoa(now))
		st.set("_bp.upto", decimal.Itoa(r.upto))
		st.del("_bp.err", "_bp.why")
		return
	}
	st.set("_bp.err", decimal.Itoa(now))
	st.set("_bp.why", clean(r.why))
}

// backupPingRow is the row of `show`:
//
//	backup-ping <masked url> <last sent> <failing since> <why nothing is sent now>
func (w Watch) backupPingRow(o *out.Writer, st *store) {
	f := w.backupPingFile()
	if !fsinfo.RegularFollow(f) {
		return
	}
	why := st.get("_bp.why")
	if st.get("_bp.err") == "" {
		_, _, why = w.backupRun(st.n("_bp.upto", 0))
	}
	o.Row("backup-ping", mask(loadQuiet(f)["url"]), st.get("_bp.ok"), st.get("_bp.err"), why)
}

// outsideRows are doctor's rows about what watches from outside: a warning while a server with
// apps has no heartbeat (nobody is told when it dies), and a failing backup ping.
func (w Watch) outsideRows(o *out.Writer, st *store, now int64) {
	if !fsinfo.RegularFollow(filepath.Join(w.Sec, "heartbeat")) {
		if names, _ := apps.Names(w.Env.Root); len(names) > 0 {
			o.Row("check", "warn", "heartbeat", "none: if this server goes down, nothing tells you. "+
				"Let an outside service expect a call from it: tando alerts heartbeat")
		}
	}
	if !fsinfo.RegularFollow(w.backupPingFile()) {
		return
	}
	if e := st.get("_bp.err"); decimal.IsDigits(e) {
		o.Row("check", "warn", "backup ping", "the request fails since "+dur(now-num(e, 0))+": "+st.or("_bp.why", "?")+
			"; tried again every 5 minutes (tando alerts backup-ping sets another URL)")
		return
	}
	if _, _, why := w.backupRun(st.n("_bp.upto", 0)); why != "" {
		o.Row("check", "ok", "backup ping", "not sent now: "+why)
	} else {
		o.Row("check", "ok", "backup ping", "sent after the last run of the daily backups")
	}
}

// setPingURL stores a URL that is requested from here (the heartbeat, the backup ping):
// "url=<url>" on stdin (a secret), or "off". what names it in the error.
func (w Watch) setPingURL(o *out.Writer, stdin io.Reader, f, what string) error {
	if err := needRoot(w.Env); err != nil {
		return err
	}
	in, err := stdinLines(stdin)
	if err != nil {
		return err
	}
	kv := arg(in, 0)
	if kv == "off" {
		os.Remove(f)
		o.KV("ok", "1")
		return nil
	}
	if !heartbeatRe.MatchString(kv) || hasCtl(kv) {
		return errf("the %s must be an http(s) URL", what)
	}
	mkdir700(w.Sec)
	if err := atomicfile.Write(f, []byte(kv+"\n"), atomicfile.Mode(0o600)); err != nil {
		return err
	}
	o.KV("ok", "1")
	return nil
}

// BackupPing is the verb `backup-ping`: "url=<url>" on stdin (a secret), or "off". A new URL
// starts fresh: it is requested at the next run if the last daily backups were whole.
func (w Watch) BackupPing(_ context.Context, o *out.Writer, stdin io.Reader) error {
	if err := needRoot(w.Env); err != nil {
		return err
	}
	l, err := w.lockBusy()
	if err != nil {
		return err
	}
	defer l.Release()
	if err := w.setPingURL(o, stdin, w.backupPingFile(), "backup ping"); err != nil {
		return err
	}
	st := newStore(loadQuiet(w.statePath()))
	st.del("_bp.ok", "_bp.upto", "_bp.err", "_bp.why")
	if st.dirty {
		return st.save(w.statePath())
	}
	return nil
}
