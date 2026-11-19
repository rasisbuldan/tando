package offsite

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"tando/srv/internal/atomicfile"
	"tando/srv/internal/bashread"
	"tando/srv/internal/kvfile"
	"tando/srv/internal/out"
)

// step prints one line of a check as the client shows `host setup`'s: step=<name> ok|fail <detail>
func step(w *out.Writer, name, st, detail string) {
	w.KV("step", name+" "+st+" "+out.Clean(detail))
}

// probe checks the settings the way backups will use them: write, read back, list, delete a
// small test object under this server's directory, and compare the clocks. Each failure says
// what is wrong (wrong key, no such bucket, no permission for this step, clock skew).
func (o Offsite) probe(ctx context.Context, w *out.Writer, c Conf, hostID string) error {
	cli, err := o.client(c)
	if err != nil {
		return err
	}
	cli.tries = min(cli.tries, 3)
	host := cli.base.Host
	fail := func(name string, err error) error {
		step(w, name, "fail", err.Error())
		if absDur(cli.skew) > 5*time.Minute {
			step(w, "clock", "fail", "this server's clock is "+absDur(cli.skew).Round(time.Second).String()+" off the storage's: request signing breaks at 15 minutes (timedatectl set-ntp true)")
		}
		return errors.New(name + " failed: " + err.Error())
	}
	pre := c.hostPrefix(hostID)
	cctx, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()
	if _, err := cli.listOne(cctx, pre, "", "", 1); err != nil {
		return fail("connect", err)
	}
	step(w, "connect", "ok", host+", bucket "+c.Bucket)
	rb := make([]byte, 16)
	io.ReadFull(o.Rand, rb)
	key := pre + ".tando-test-" + hexString(rb[:6])
	body := []byte("tando offsite test " + hexString(rb) + "\n")
	if err := cli.put(cctx, key, body, "text/plain"); err != nil {
		return fail("write", err)
	}
	step(w, "write", "ok", "a test object under "+pre)
	got, err := cli.getSmall(cctx, key, 4096)
	if err != nil {
		cli.del(cctx, key)
		return fail("read", err)
	}
	if !bytes.Equal(got, body) {
		cli.del(cctx, key)
		return fail("read", errors.New("the object read back differs from what was written"))
	}
	step(w, "read", "ok", "the same bytes came back")
	lp, err := cli.listOne(cctx, key, "", "", 10)
	if err != nil {
		cli.del(cctx, key)
		return fail("list", err)
	}
	if len(lp.Objects) != 1 || lp.Objects[0].Key != key {
		cli.del(cctx, key)
		return fail("list", errors.New("the test object is not listed"))
	}
	step(w, "list", "ok", "")
	if err := cli.del(cctx, key); err != nil {
		return fail("delete", err)
	}
	if _, ok, err := cli.head(cctx, key); err != nil || ok {
		return fail("delete", errors.New("the test object is still there after its delete"))
	}
	step(w, "delete", "ok", "")
	if absDur(cli.skew) > 5*time.Minute {
		step(w, "clock", "fail", "this server's clock is "+absDur(cli.skew).Round(time.Second).String()+" off the storage's: request signing breaks at 15 minutes (timedatectl set-ntp true)")
		return errors.New("clock skew")
	}
	step(w, "clock", "ok", "within "+absDur(cli.skew).Round(time.Second).String()+" of the storage's")
	return nil
}

// readSettings: key=value lines from stdin (at most 64 KiB), only known keys
func readSettings(r io.Reader) (map[string]string, error) {
	b, err := io.ReadAll(io.LimitReader(r, 64<<10))
	if err != nil {
		return nil, err
	}
	m := map[string]string{}
	for _, l := range strings.Split(string(b), "\n") {
		l = strings.TrimRight(l, "\r")
		if l == "" || strings.HasPrefix(l, "#") {
			continue
		}
		k, v, ok := strings.Cut(l, "=")
		if !ok || !settable[k] {
			return nil, fmt.Errorf("unknown setting: %s", out.Clean(k))
		}
		m[k] = v
	}
	return m, nil
}

// Set is the verb `set` (settings on stdin, key=value): it merges them with the current ones,
// checks them against the bucket, and only then saves them, makes the recovery key (once; shown
// in this output and never again unless asked), installs the timer and queues the newest backup
// of each app.
func (o Offsite) Set(ctx context.Context, w *out.Writer, stdin io.Reader) error {
	if err := o.needRoot(); err != nil {
		return err
	}
	in, err := readSettings(stdin)
	if err != nil {
		return err
	}
	m := map[string]string{}
	old, had, err := loadConf(o.Conf, o.Owner)
	if err != nil && len(in) < 4 {
		return err
	}
	if had {
		m = old.fields()
	}
	if _, ok := in["account_id"]; ok {
		delete(m, "endpoint")
	}
	for k, v := range in {
		m[k] = v
	}
	if !had {
		m["since"] = strconv.FormatInt(o.now(), 10)
	}
	c, err := confFrom(m)
	if err != nil {
		return err
	}
	o.ensureDirs()
	hostID, err := o.hostID(true)
	if err != nil {
		return err
	}
	if err := o.probe(ctx, w, c, hostID); err != nil {
		return fmt.Errorf("%v; nothing was saved", err)
	}
	b, err := kvfile.Format(c.fields())
	if err != nil {
		return err
	}
	if err := atomicfile.Write(o.Conf, b, modeOf(0o600)); err != nil {
		return err
	}
	o.credsResult(nil)
	if c.Encrypt {
		keys, err := loadKeys(o.KeyFile, o.Owner)
		if err != nil {
			return err
		}
		if _, ok := currentKey(keys); !ok {
			k, err := NewKey(o.Rand, o.now())
			if err != nil {
				return err
			}
			if err := saveKeys(o.KeyFile, append(keys, k)); err != nil {
				return err
			}
			w.KV("key_new", "1")
			w.KV("key", k.Text())
		}
		k, _ := currentKey(o.mustKeys())
		w.KV("key_id", k.IDHex())
	}
	if err := o.installUnits(ctx); err != nil {
		return fmt.Errorf("the settings were saved, but the timer could not be installed: %w", err)
	}
	queued := 0
	for _, a := range o.backupApps() {
		bs := o.localBackups(a)
		if len(bs) > 0 && len(bs[0].state) == 0 {
			o.saveBackupState(a, bs[0].id, map[string]string{"state": "pending"})
			queued++
		}
		o.refreshBrief(a, &c)
	}
	o.kick(ctx)
	w.KV("saved", "1")
	w.KV("host_id", hostID)
	w.KV("queued", strconv.Itoa(queued))
	w.KV("encrypt", c.fields()["encrypt"])
	return nil
}

func (o Offsite) mustKeys() []Key { ks, _ := loadKeys(o.KeyFile, o.Owner); return ks }

// Test is the verb `test`: the probe with the saved settings.
func (o Offsite) Test(ctx context.Context, w *out.Writer) error {
	if err := o.needRoot(); err != nil {
		return err
	}
	c, ok, err := loadConf(o.Conf, o.Owner)
	if err != nil {
		return err
	}
	if !ok {
		return errOff
	}
	id, err := o.hostID(false)
	if err != nil {
		return err
	}
	err = o.probe(ctx, w, c, id)
	o.credsResult(credsErrOnly(err))
	return err
}

// Off is the verb `off`: no more uploads (the timer goes, the settings and credentials too); the
// recovery key, the host id and everything in the bucket stay.
func (o Offsite) Off(ctx context.Context, w *out.Writer) error {
	if err := o.needRoot(); err != nil {
		return err
	}
	o.removeUnits(ctx)
	if err := os.Remove(o.Conf); err != nil && !isNotExist(err) {
		return err
	}
	for _, a := range o.backupApps() {
		o.refreshBrief(a, nil)
	}
	os.Remove(o.hostStatePath())
	w.KV("off", "1")
	return nil
}

func maskKeyID(s string) string {
	if len(s) <= 8 {
		return s[:min(2, len(s))] + "…"
	}
	return s[:4] + "…" + s[len(s)-4:]
}

// Status is the verb `status`: the settings (never the secret), the key, the last check and per
// app the brief's numbers (rows `app <name> <pending> <failed> <last upload> <oldest pending> <error>`).
func (o Offsite) Status(ctx context.Context, w *out.Writer) error {
	if err := o.needRoot(); err != nil {
		return err
	}
	keys, kerr := loadKeys(o.KeyFile, o.Owner)
	c, ok, err := loadConf(o.Conf, o.Owner)
	if err != nil {
		return err
	}
	if !ok {
		w.KV("configured", "0")
		if len(keys) > 0 {
			k, _ := currentKey(keys)
			w.KV("key_id", k.IDHex())
		}
		return nil
	}
	id, _ := o.hostID(false)
	u, _ := url.Parse(c.Endpoint)
	w.KV("configured", "1")
	w.KV("endpoint", c.Endpoint)
	if strings.HasSuffix(u.Hostname(), ".r2.cloudflarestorage.com") {
		w.KV("provider", "Cloudflare R2")
	}
	w.KV("bucket", c.Bucket)
	w.KV("prefix", c.Prefix)
	w.KV("region", c.Region)
	w.KV("access_key_id", maskKeyID(c.AccessKey))
	w.KV("host_id", id)
	w.KV("hostname", o.Hostname)
	w.KV("encrypt", c.fields()["encrypt"])
	if kerr != nil {
		w.KV("key_error", kerr.Error())
	} else if k, ok := currentKey(keys); ok {
		w.KV("key_id", k.IDHex())
		w.KV("key_saved", strconv.FormatInt(k.Saved, 10))
		w.KV("keys", strconv.Itoa(len(keys)))
	}
	w.KV("alert_hours", strconv.Itoa(c.AlertHours))
	w.KV("keep", fmt.Sprintf("daily %d, weekly %d, monthly %d, other %d each, final all, newest %d always",
		c.Keep.Daily, c.Keep.Weekly, c.Keep.Monthly, c.Keep.Other, c.Keep.Min))
	hs := o.loadHostState()
	for _, k := range []string{"creds", "creds_error", "creds_since", "checked", "inventory", "skew"} {
		w.KV(k, hs[k])
	}
	if o.systemctl(ctx, "is-active", "-q", "tando-offsite.timer") == nil {
		w.KV("timer", "active")
	} else {
		w.KV("timer", "inactive")
	}
	apps := map[string]bool{}
	for _, a := range o.backupApps() {
		apps[a] = true
	}
	for _, a := range sortedKeys(apps) {
		o.refreshBrief(a, &c)
		b, _ := kvfile.Load(o.briefPath(a))
		w.Row("app", a, b["pending"], b["failed"], b["last_upload"], b["oldest_pending"], b["error"])
	}
	return nil
}

// Brief is the verb `brief [app]`: rows
//
//	offsite <app> <ok|pending|late|failing|off> <last upload> <pending> <oldest pending> <alert hours> <detail>
//
// late: a backup has waited longer than alert_hours; failing: the credentials stopped working.
// (tando-watch can read the state files themselves: see state.go.)
func (o Offsite) Brief(w *out.Writer, only string) error {
	if only != "" {
		if err := checkApp(only); err != nil {
			return err
		}
	}
	ents, _ := os.ReadDir(o.Dir + "/state")
	for _, e := range ents {
		a := e.Name()
		if checkApp(a) != nil || (only != "" && a != only) {
			continue
		}
		b, err := kvfile.Load(o.briefPath(a))
		if err != nil {
			continue
		}
		st, det := BriefState(b, o.now())
		w.Row("offsite", a, st, b["last_upload"], b["pending"], b["oldest_pending"], b["alert_hours"], det)
	}
	return nil
}

// BriefState: what a brief (state file) says at time now, and why
func BriefState(b map[string]string, now int64) (string, string) {
	if b["enabled"] != "1" {
		return "off", ""
	}
	if b["creds"] == "failing" {
		return "failing", "offsite credentials fail: " + b["creds_error"]
	}
	ah := num(b["alert_hours"])
	if ah <= 0 {
		ah = 6
	}
	if op := num(b["oldest_pending"]); op > 0 {
		if now-op > ah*3600 {
			d := "backup " + b["oldest_pending_id"] + " not offsite after " + strconv.FormatInt((now-op)/3600, 10) + "h"
			if b["error"] != "" {
				d += ": " + b["error"]
			}
			return "late", d
		}
		return "pending", b["pending"] + " waiting"
	}
	return "ok", ""
}

func sortedKeys(m map[string]bool) []string {
	var r []string
	for k := range m {
		r = append(r, k)
	}
	for i := 1; i < len(r); i++ {
		for j := i; j > 0 && r[j] < r[j-1]; j-- {
			r[j], r[j-1] = r[j-1], r[j]
		}
	}
	return r
}

// ---- the recovery key ------------------------------------------------------------------------

// KeyShow is the verb `key-show`: every key (rows `key <id> <text> <current|old> <saved>`);
// the client asks for confirmation before it calls this.
func (o Offsite) KeyShow(w *out.Writer) error {
	if err := o.needRoot(); err != nil {
		return err
	}
	ks, err := loadKeys(o.KeyFile, o.Owner)
	if err != nil {
		return err
	}
	if len(ks) == 0 {
		return errors.New("no recovery key on this server (tando backup offsite set makes one)")
	}
	for _, k := range ks {
		role := "old"
		if k.Current {
			role = "current"
		}
		w.Row("key", k.IDHex(), k.Text(), role, strconv.FormatInt(k.Saved, 10))
	}
	return nil
}

// KeySaved is the verb `key-saved`: the admin confirms every key is stored safely elsewhere.
func (o Offsite) KeySaved(w *out.Writer) error {
	if err := o.needRoot(); err != nil {
		return err
	}
	ks, err := loadKeys(o.KeyFile, o.Owner)
	if err != nil {
		return err
	}
	if len(ks) == 0 {
		return errors.New("no recovery key on this server (tando backup offsite set makes one)")
	}
	for i := range ks {
		if ks[i].Saved == 0 {
			ks[i].Saved = o.now()
		}
	}
	if err := saveKeys(o.KeyFile, ks); err != nil {
		return err
	}
	w.KV("saved", strconv.Itoa(len(ks)))
	return nil
}

// KeyImport is the verb `key-import` (the key's text on stdin): it becomes the current key, so
// that a new server goes on with the key the admin already stores; the one it replaces is kept
// for reading.
func (o Offsite) KeyImport(w *out.Writer, stdin io.Reader) error {
	if err := o.needRoot(); err != nil {
		return err
	}
	b, _ := io.ReadAll(io.LimitReader(stdin, 4096))
	k, err := ParseKey(string(b))
	if err != nil {
		return err
	}
	ks, err := loadKeys(o.KeyFile, o.Owner)
	if err != nil {
		return err
	}
	found := false
	for i := range ks {
		ks[i].Current = ks[i].ID() == k.ID()
		found = found || ks[i].Current
		if ks[i].Current && ks[i].Saved == 0 {
			ks[i].Saved = o.now() // (the admin had it to type it)
		}
	}
	if !found {
		k.Created, k.Current, k.Saved = o.now(), true, o.now()
		ks = append(ks, k)
	}
	if err := saveKeys(o.KeyFile, ks); err != nil {
		return err
	}
	w.KV("key_id", k.IDHex())
	w.KV("keys", strconv.Itoa(len(ks)))
	return nil
}

// KeyRotate is the verb `key-rotate`: a new current key for new uploads (shown once); the old
// ones stay for reading what they encrypted.
func (o Offsite) KeyRotate(w *out.Writer) error {
	if err := o.needRoot(); err != nil {
		return err
	}
	ks, err := loadKeys(o.KeyFile, o.Owner)
	if err != nil {
		return err
	}
	k, err := NewKey(o.Rand, o.now())
	if err != nil {
		return err
	}
	for i := range ks {
		ks[i].Current = false
	}
	ks = append(ks, k)
	if err := saveKeys(o.KeyFile, ks); err != nil {
		return err
	}
	w.KV("key", k.Text())
	w.KV("key_id", k.IDHex())
	w.KV("keys", strconv.Itoa(len(ks)))
	return nil
}

// ---- doctor ----------------------------------------------------------------------------------

// Doctor is the verb `doctor`: rows `check <ok|warn|fail> <name> <detail>` for tando doctor.
func (o Offsite) Doctor(ctx context.Context, w *out.Writer) error {
	c, ok, err := loadConf(o.Conf, o.Owner)
	if err != nil {
		w.Row("check", "fail", "offsite", err.Error())
		return nil
	}
	if !ok {
		w.Row("check", "ok", "offsite", "off (tando backup offsite set)")
		return nil
	}
	hs := o.loadHostState()
	where := "bucket " + c.Bucket
	if hs["creds"] == "failing" {
		w.Row("check", "fail", "offsite", where+": the credentials fail since "+ago(o.now(), num(hs["creds_since"]))+": "+hs["creds_error"]+" (tando backup offsite set)")
	} else {
		w.Row("check", "ok", "offsite", where+", "+map[bool]string{true: "encrypted", false: "NOT encrypted"}[c.Encrypt])
	}
	var pending, failed, last int64
	late := ""
	for _, a := range o.backupApps() {
		o.refreshBrief(a, &c)
		b, _ := kvfile.Load(o.briefPath(a))
		pending += num(b["pending"])
		failed += num(b["failed"])
		last = max(last, num(b["last_upload"]))
		if st, det := BriefState(b, o.now()); st == "late" && late == "" {
			late = a + ": " + det
		}
	}
	lu := "no upload yet"
	if last > 0 {
		lu = "last upload " + ago(o.now(), last)
	}
	switch {
	case late != "":
		w.Row("check", "warn", "offsite queue", late+" (tando backup offsite status)")
	case pending > 0:
		w.Row("check", "ok", "offsite queue", fmt.Sprintf("%d waiting (%d failed); %s", pending, failed, lu))
	default:
		w.Row("check", "ok", "offsite queue", "nothing waiting; "+lu)
	}
	if o.systemctl(ctx, "is-active", "-q", "tando-offsite.timer") != nil {
		w.Row("check", "fail", "offsite timer", "tando-offsite.timer is not active: failed uploads are not retried (tando backup offsite set installs it)")
	}
	if c.Encrypt {
		ks, err := loadKeys(o.KeyFile, o.Owner)
		switch {
		case err != nil:
			w.Row("check", "fail", "recovery key", err.Error())
		case len(ks) == 0:
			w.Row("check", "fail", "recovery key", "missing: nothing can be uploaded (tando backup offsite key --import)")
		default:
			unsaved := 0
			for _, k := range ks {
				if k.Saved == 0 {
					unsaved++
				}
			}
			k, _ := currentKey(ks)
			if unsaved > 0 {
				w.Row("check", "warn", "recovery key", "not confirmed saved: without it the offsite backups are unreadable. Store it (tando backup offsite key --show), then: tando backup offsite key --saved")
			} else {
				w.Row("check", "ok", "recovery key", "key "+k.IDHex()+", saved by the admin")
			}
		}
	}
	return nil
}

func ago(now, t int64) string {
	if t <= 0 {
		return "never"
	}
	d := now - t
	switch {
	case d < 120:
		return strconv.FormatInt(max(d, 0), 10) + "s ago"
	case d < 7200:
		return strconv.FormatInt(d/60, 10) + "m ago"
	case d < 172800:
		return strconv.FormatInt(d/3600, 10) + "h ago"
	}
	return strconv.FormatInt(d/86400, 10) + "d ago"
}

// ---- disaster recovery: recreate apps of another server --------------------------------------

// confKeys: the app.conf settings `tando-agent configure` takes (the others are the server's own:
// port, created, origin, user, data_dir ...)
var confKeys = map[string]bool{
	"recipe": true, "image": true, "container_port": true, "build_memory": true, "start": true,
	"start_shell": true, "health": true, "path": true, "data": true, "writable": true, "backup": true,
	"database": true, "memory": true, "health_timeout": true, "soak": true, "cpu": true, "tasks": true,
	"max_conns": true, "max_requests": true, "stop_timeout": true, "hold": true, "log_max": true,
	"log_keep": true, "log_rate": true, "access_log": true, "request_log_max": true,
	"health_expect": true, "health_fails": true, "health_recover": true,
	"db_statement_timeout": true, "db_idle_tx_timeout": true, "db_temp_limit": true,
}

func (o Offsite) drOpen(host string) (*session, error) {
	if err := o.needRoot(); err != nil {
		return nil, err
	}
	if !ValidHostID(host) {
		return nil, errors.New("bad host id (tando backup offsite hosts lists them)")
	}
	return o.open()
}

func parseConf(b []byte) map[string]string {
	m, _ := kvfile.Parse(bytes.NewReader(b))
	return m
}

// DrPlan is the verb `dr-plan <host id> [app...]`: per app of that server in the bucket, a row
//
//	app <name> <recipe> <database> <newest backup id|-> <domains: d|www,...> <origin> <adopted: 1|0>
func (o Offsite) DrPlan(ctx context.Context, w *out.Writer, host string, only []string) error {
	s, err := o.drOpen(host)
	if err != nil {
		return err
	}
	for _, a := range only {
		if err := checkApp(a); err != nil {
			return fmt.Errorf("%v: %s", err, out.Clean(a))
		}
	}
	pre := s.conf.rootPrefix() + host + "/"
	lp, err := s.cli.list(ctx, pre, "/", 20)
	if err != nil {
		return err
	}
	if len(lp.Prefixes) == 0 && len(lp.Objects) == 0 {
		return fmt.Errorf("no server %s in this bucket (tando backup offsite hosts lists them)", host)
	}
	found := map[string]bool{}
	for _, p := range lp.Prefixes {
		a := strings.TrimSuffix(strings.TrimPrefix(p, pre), "/")
		if checkApp(a) != nil {
			continue
		}
		found[a] = true
	}
	for _, a := range only {
		if !found[a] {
			return fmt.Errorf("server %s has no app %s in the bucket", host, a)
		}
	}
	for _, a := range sortedKeys(found) {
		if len(only) > 0 && !contains(only, a) {
			continue
		}
		rb, err := o.remoteBackups(ctx, s, host, a)
		if err != nil {
			return err
		}
		newest := "-"
		if len(rb) > 0 {
			newest = rb[0].id
		}
		files, err := o.readConfig(ctx, s, host, a, "app.rbk")
		var conf map[string]string
		if err == nil {
			conf = parseConf(files["config/app.conf"])
		} else {
			var se *S3Error
			if !errors.As(err, &se) || se.Code != "NoSuchKey" {
				return fmt.Errorf("%s: %w", a, err)
			}
			conf = map[string]string{}
		}
		adopted := "0"
		if conf["user"] != "" || conf["data_dir"] != "" {
			adopted = "1"
		}
		w.Row("app", a, conf["recipe"], conf["database"], newest, strings.ReplaceAll(conf["domains"], " ", ","), conf["origin"], adopted)
	}
	return nil
}

func contains(l []string, s string) bool {
	for _, x := range l {
		if x == s {
			return true
		}
	}
	return false
}

// DrConf is the verb `dr-conf <host id> <app>`: the app's settings as `tando-agent configure`
// reads them (key=value lines), from its app.rbk object.
func (o Offsite) DrConf(ctx context.Context, w *out.Writer, host, app string) error {
	s, err := o.drOpen(host)
	if err != nil {
		return err
	}
	if err := checkApp(app); err != nil {
		return err
	}
	files, err := o.readConfig(ctx, s, host, app, "app.rbk")
	if err != nil {
		return err
	}
	conf := parseConf(files["config/app.conf"])
	if len(conf) == 0 {
		return fmt.Errorf("no app.conf of %s in the bucket", app)
	}
	for _, k := range sortedKeys(boolKeys(conf)) {
		if confKeys[k] || (strings.HasPrefix(k, "job.") && len(k) > 4) {
			w.KV(k, conf[k])
		}
	}
	return nil
}

func boolKeys(m map[string]string) map[string]bool {
	r := map[string]bool{}
	for k := range m {
		r[k] = true
	}
	return r
}

// envLines decodes the agent's env file (KEY="value" with \ escapes) into KEY=value lines,
// without the keys tando sets itself
func envLines(b []byte, postgres bool) []string {
	var r []string
	for _, l := range bashread.Lines(b) {
		k, v, ok := strings.Cut(l, "=")
		if !ok || k == "" {
			continue
		}
		switch k {
		case "PORT", "HOME", "TANDO_DATA_DIR", "DATABASE_PATH":
			continue
		case "DATABASE_URL":
			if postgres {
				continue
			}
		}
		v = strings.TrimPrefix(v, `"`)
		v = strings.TrimSuffix(v, `"`)
		var o strings.Builder
		for i := 0; i < len(v); i++ {
			if v[i] == '\\' && i+1 < len(v) {
				i++
			}
			o.WriteByte(v[i])
		}
		r = append(r, k+"="+o.String())
	}
	return r
}

// DrEnv is the verb `dr-env <host id> <app>`: the app's env from the bucket as KEY=value lines,
// without the keys tando sets itself. The client pipes it into `tando-agent env-set <app>` on
// the server, in one ssh command (sudo tando-offsite dr-env ... | sudo tando-agent env-set ...):
// the values never leave the server.
func (o Offsite) DrEnv(ctx context.Context, w *out.Writer, host, app string) error {
	s, err := o.drOpen(host)
	if err != nil {
		return err
	}
	if err := checkApp(app); err != nil {
		return err
	}
	files, err := o.readConfig(ctx, s, host, app, "app.rbk")
	if err != nil {
		return err
	}
	conf := parseConf(files["config/app.conf"])
	for _, l := range envLines(files["config/env"], conf["database"] == "postgres") {
		k, v, _ := strings.Cut(l, "=")
		w.KV(k, v)
	}
	return nil
}
