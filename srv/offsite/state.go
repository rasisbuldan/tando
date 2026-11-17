package offsite

import (
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"

	"tando/srv/internal/atomicfile"
	"tando/srv/internal/fsinfo"
	"tando/srv/internal/kvfile"
	"tando/srv/internal/out"
	"tando/srv/internal/valid"
)

func modeOf(m fs.FileMode) atomicfile.Perm { return atomicfile.Mode(m) }

// Per backup, next to it: /var/backups/tando/<app>/<id>/offsite (root 600, in root's 700
// directory), so that it goes when the backup is pruned.
//
//	state=pending|uploading|uploaded|failed
//	tries=<n>  next_try=<epoch>  error=<last error>  upload_id=<multipart upload in progress>
//	uploaded=<epoch>  object=<key>  size=<bytes>  sha256=<of the object>
//	source=<host id>        (a backup fetched from the bucket: not uploaded again)

func (o Offsite) backupDir(app, id string) string { return filepath.Join(o.Backups, app, id) }

func (o Offsite) loadBackupState(app, id string) map[string]string {
	m, err := kvfile.Load(filepath.Join(o.backupDir(app, id), "offsite"))
	if err != nil {
		return map[string]string{}
	}
	return m
}

func (o Offsite) saveBackupState(app, id string, m map[string]string) error {
	_, err := kvfile.Save(filepath.Join(o.backupDir(app, id), "offsite"), cleanMap(m), modeOf(0o600))
	return err
}

// cleanMap: values one line, no controls (error texts come from the network)
func cleanMap(m map[string]string) map[string]string {
	r := make(map[string]string, len(m))
	for k, v := range m {
		v = out.Clean(v)
		if len(v) > 300 {
			v = v[:300]
		}
		r[k] = v
	}
	return r
}

func num(s string) int64 { n, _ := strconv.ParseInt(s, 10, 64); return n }

// localBackup is a backup directory on this server.
type localBackup struct {
	id      string
	created int64
	state   map[string]string
}

// localBackups: the app's backups, newest first (ids sort by time)
func (o Offsite) localBackups(app string) []localBackup {
	ents, err := os.ReadDir(filepath.Join(o.Backups, app))
	if err != nil {
		return nil
	}
	var r []localBackup
	for _, e := range ents {
		id := e.Name()
		if !ValidBackupID(id) || !fsinfo.DirNoFollow(o.backupDir(app, id)) {
			continue
		}
		m, _ := kvfile.Load(filepath.Join(o.backupDir(app, id), "meta"))
		c := num(m["created"])
		if c == 0 {
			c = backupTime(id)
		}
		r = append(r, localBackup{id: id, created: c, state: o.loadBackupState(app, id)})
	}
	sort.Slice(r, func(i, j int) bool { return r[i].id > r[j].id })
	return r
}

// backupApps: the apps with a backup directory
func (o Offsite) backupApps() []string {
	ents, err := os.ReadDir(o.Backups)
	if err != nil {
		return nil
	}
	var r []string
	for _, e := range ents {
		if valid.App(e.Name()) && fsinfo.DirNoFollow(filepath.Join(o.Backups, e.Name())) {
			r = append(r, e.Name())
		}
	}
	return r
}

// wanted: this backup should be (or have been) uploaded. A backup with a state file always;
// one without only when it was made after offsite was turned on (older ones stay local, but for
// the newest of each app, which set queues).
func wanted(b localBackup, since int64) bool {
	if len(b.state) > 0 {
		return true
	}
	return since > 0 && b.created >= since
}

// The host's state: /var/lib/tando/offsite/host (644)
//
//	creds=ok|failing  checked=<epoch>  creds_error=<why>  creds_since=<epoch failing since>
//	inventory=<epoch of the last inventory upload>  skew=<seconds the storage's clock is ahead>
func (o Offsite) hostStatePath() string { return filepath.Join(o.Dir, "host") }

func (o Offsite) loadHostState() map[string]string {
	m, err := kvfile.Load(o.hostStatePath())
	if err != nil {
		return map[string]string{}
	}
	return m
}

func (o Offsite) saveHostState(m map[string]string) {
	o.ensureDirs()
	kvfile.Save(o.hostStatePath(), cleanMap(m), modeOf(0o644))
}

// credsResult records a check of the credentials
func (o Offsite) credsResult(err error) {
	m := o.loadHostState()
	now := strconv.FormatInt(o.now(), 10)
	m["checked"] = now
	if err == nil {
		m["creds"], m["creds_error"], m["creds_since"] = "ok", "", ""
	} else {
		if m["creds"] != "failing" {
			m["creds_since"] = now
		}
		m["creds"], m["creds_error"] = "failing", err.Error()
	}
	o.saveHostState(m)
}

func (o Offsite) ensureDirs() {
	for _, d := range []string{o.Dir, filepath.Join(o.Dir, "state")} {
		os.MkdirAll(d, 0o755)
		os.Chmod(d, 0o755) // (whatever the umask: the briefs are read by tando status)
	}
	os.MkdirAll(filepath.Join(o.Dir, "locks"), 0o700)
}

// The per-app brief: /var/lib/tando/offsite/state/<app> (644), rewritten after every upload
// attempt and every sync. tando-watch's backup check and tando status read it (docs/BACKUP.md,
// "Monitoring"):
//
//	enabled=1|0
//	alert_hours=6           a backup not offsite after this many hours is late
//	pending=<n>             local backups not (yet) offsite
//	failed=<n>              of them, how many failed their last attempt
//	oldest_pending=<epoch>  when the oldest of them was made (0: none)
//	oldest_pending_id=<id>
//	last_upload=<epoch>     the last backup that reached the bucket (0: none yet)
//	last_upload_id=<id>
//	error=<the last upload error>
//	creds=ok|failing        the bucket's credentials at the last check
//	creds_error=<why>
//	checked=<epoch>         that check
func (o Offsite) briefPath(app string) string { return filepath.Join(o.Dir, "state", app) }

// refreshBrief recomputes the app's brief from its backups' states
func (o Offsite) refreshBrief(app string, c *Conf) {
	if c == nil {
		os.Remove(o.briefPath(app))
		return
	}
	o.ensureDirs()
	hs := o.loadHostState()
	var pending, failed, oldest, last int64
	var oldestID, lastID, lastErr string
	for _, b := range o.localBackups(app) {
		st := b.state["state"]
		switch {
		case st == "uploaded":
			if u := num(b.state["uploaded"]); u > last && b.state["source"] == "" {
				last, lastID = u, b.id
			}
		case wanted(b, c.Since):
			pending++
			if st == "failed" {
				failed++
				if lastErr == "" {
					lastErr = b.state["error"]
				}
			}
			if oldest == 0 || b.created < oldest {
				oldest, oldestID = b.created, b.id
			}
		}
	}
	// what an earlier brief knew of uploads whose backups were pruned since
	if old, _ := kvfile.Load(o.briefPath(app)); num(old["last_upload"]) > last {
		last, lastID = num(old["last_upload"]), old["last_upload_id"]
	}
	m := map[string]string{
		"enabled": "1", "alert_hours": strconv.Itoa(c.AlertHours),
		"pending": strconv.FormatInt(pending, 10), "failed": strconv.FormatInt(failed, 10),
		"oldest_pending": strconv.FormatInt(oldest, 10), "oldest_pending_id": oldestID,
		"last_upload": strconv.FormatInt(last, 10), "last_upload_id": lastID, "error": lastErr,
		"creds": hs["creds"], "creds_error": hs["creds_error"], "checked": hs["checked"],
	}
	kvfile.Save(o.briefPath(app), cleanMap(m), modeOf(0o644))
}
