package watch

import (
	"context"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"tando/srv/internal/decimal"
	"tando/srv/internal/fsinfo"
	"tando/srv/internal/out"
)

// pingRec is a Sender that records the URLs pinged and answers err.
type pingRec struct {
	mu   sync.Mutex
	urls []string
	err  error
}

func (p *pingRec) Post(context.Context, string, [][2]string, []byte) (int, error) { return 200, nil }
func (p *pingRec) Ping(_ context.Context, u string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.urls = append(p.urls, u)
	return p.err
}

const bpURL = "https://hc.example/ping/B4CKUP"

type bpHost struct {
	*fakeHost
	rec *pingRec
}

func newBPHost(t *testing.T) bpHost {
	f := newFakeHost(t)
	f.write("opt/alerts.d/backup-ping", "url="+bpURL+"\n")
	return bpHost{f, &pingRec{}}
}

func (h bpHost) watch() Watch {
	w := h.fakeHost.watch()
	w.Send, w.Backups = h.rec, h.path("backups")
	return w
}

// tick runs the checks once, a minute later; it returns how many backup pings that run sent.
func (h bpHost) tick() int {
	h.t.Helper()
	before := len(h.rec.urls)
	h.setUptime()
	if err := h.watch().Run(context.Background()); err != nil {
		h.t.Fatalf("run: %v", err)
	}
	h.now = h.now.Add(time.Minute)
	for _, u := range h.rec.urls[before:] {
		if u != bpURL {
			h.t.Fatalf("pinged %q", u)
		}
	}
	return len(h.rec.urls) - before
}

// daily records the outcome of an app's daily backup as the agent does (ago: seconds before now).
func (h bpHost) daily(app string, ok bool, id string) {
	now := decimal.Itoa(h.now.Unix())
	st := "current=20261114-170102\nphase=idle\n"
	old := loadQuiet(h.path("opt/apps/" + app + "/state"))
	if ok {
		st += "backup_daily_ok=" + now + "\nbackup_daily_id=" + id + "\n"
	} else {
		st += "backup_daily_ok=" + old["backup_daily_ok"] + "\nbackup_daily_id=" + old["backup_daily_id"] + "\nbackup_daily_failed=" + now + "\n"
	}
	h.write("opt/apps/"+app+"/state", st)
	h.now = h.now.Add(time.Second)
}

func TestBackupPingOncePerWholeRun(t *testing.T) {
	h := newBPHost(t)
	h.app("blog", "backup=daily")
	h.app("shop", "backup=daily")
	h.app("site") // no data: no backups, never waited for
	if n := h.tick(); n != 0 {
		t.Fatalf("no daily backup has run yet: %d pings", n)
	}
	h.daily("blog", true, "20270115-000001-daily")
	if n := h.tick(); n != 0 {
		t.Fatalf("shop has not run yet: %d pings", n)
	}
	h.daily("shop", true, "20270115-000002-daily")
	if n := h.tick(); n != 1 {
		t.Fatalf("both apps backed up: %d pings, want 1", n)
	}
	if n := h.tick() + h.tick(); n != 0 {
		t.Fatalf("pinged again for the same run: %d", n)
	}
	if _, _, why := h.watch().backupRun(num(h.st("_bp.upto"), 0)); why != "" {
		t.Errorf("idle after a ping, yet: %q", why)
	}
	// the next day: one app fails
	h.daily("blog", true, "20270116-000001-daily")
	h.daily("shop", false, "")
	if n := h.tick() + h.tick(); n != 0 {
		t.Fatalf("a failed backup pinged: %d", n)
	}
	if _, _, why := h.watch().backupRun(num(h.st("_bp.upto"), 0)); why != "the last daily backup of shop failed" {
		t.Errorf("why: %q", why)
	}
	o, _ := do(func(o *out.Writer) error { return h.watch().Show(context.Background(), o, nil) })
	if !strings.Contains(o, "backup-ping\thttps://hc.example/…\t") || !strings.Contains(o, "\tthe last daily backup of shop failed\n") ||
		strings.Contains(o, "B4CKUP") {
		t.Errorf("show: %q", o)
	}
	// it is run again and succeeds: the run is whole
	h.daily("shop", true, "20270116-000500-daily")
	if n := h.tick(); n != 1 {
		t.Fatalf("after the repeat: %d pings, want 1", n)
	}
	// a third day where only one app runs (the other's timer is gone)
	h.daily("blog", true, "20270117-000001-daily")
	if n := h.tick(); n != 0 {
		t.Fatalf("shop did not run: %d pings", n)
	}
	if _, _, why := h.watch().backupRun(num(h.st("_bp.upto"), 0)); why != "waiting for the next daily backup of shop" {
		t.Errorf("why: %q", why)
	}
}

func TestBackupPingNeedsTheOffsiteCopy(t *testing.T) {
	h := newBPHost(t)
	h.app("blog", "backup=daily")
	h.write("opt/offsite.conf", "bucket=b\n")
	id := "20270115-000001-daily"
	h.daily("blog", true, id)
	if n := h.tick(); n != 0 {
		t.Fatalf("not offsite yet: %d pings", n)
	}
	h.write("backups/blog/"+id+"/offsite", "state=uploading\n")
	if n := h.tick(); n != 0 {
		t.Fatalf("still uploading: %d pings", n)
	}
	if _, _, why := h.watch().backupRun(0); why != "the daily backup of blog is not offsite yet" {
		t.Errorf("why: %q", why)
	}
	h.write("backups/blog/"+id+"/offsite", "state=uploaded\n")
	if n := h.tick(); n != 1 {
		t.Fatalf("uploaded: %d pings, want 1", n)
	}
	// an id that is no daily backup's is never looked up
	if h.watch().backupOffsite("blog", "../../x") {
		t.Errorf("a bad id counted as offsite")
	}
}

func TestBackupPingFailureIsShownAndRetried(t *testing.T) {
	h := newBPHost(t)
	h.app("blog", "backup=daily")
	h.daily("blog", true, "20270115-000001-daily")
	h.rec.err = failed("timed out")
	if n := h.tick(); n != 1 {
		t.Fatalf("first attempt: %d", n)
	}
	if h.st("_bp.why") != "timed out" || h.st("_bp.err") == "" || h.st("_bp.ok") != "" {
		t.Errorf("state: %v", h.state())
	}
	o, _ := do(func(o *out.Writer) error { h.watch().Doctor(context.Background(), o); return nil })
	if !strings.Contains(o, "check\twarn\tbackup ping\tthe request fails since 1m 0s: timed out;") {
		t.Errorf("doctor: %q", o)
	}
	if n := h.tick() + h.tick() + h.tick(); n != 0 {
		t.Fatalf("retried within 5 minutes: %d", n)
	}
	h.rec.err = nil
	if n := h.tick() + h.tick(); n != 1 {
		t.Fatalf("retry after 5 minutes: %d, want 1", n)
	}
	if h.st("_bp.err") != "" || h.st("_bp.ok") == "" {
		t.Errorf("state after the retry: %v", h.state())
	}
	if n := h.tick(); n != 0 {
		t.Fatalf("pinged twice: %d", n)
	}
}

func TestBackupPingVerb(t *testing.T) {
	f := newFakeHost(t)
	w := f.watch()
	set := func(in string) (string, error) {
		return do(func(o *out.Writer) error { return w.BackupPing(context.Background(), o, strings.NewReader(in)) })
	}
	for _, in := range []string{"url=ftp://x\n", "url=http://x/a b\n", "http://x\n"} {
		if _, err := set(in); err == nil || err.Error() != "the backup ping must be an http(s) URL" {
			t.Errorf("%q: %v", in, err)
		}
	}
	f.write("lib/watch/state", "_bp.ok=5\n_bp.upto=4\n_bp.err=6\n_bp.why=x\n_sil.all=99\n")
	if o, err := set("url=" + bpURL + "\n"); err != nil || o != "ok=1\n" {
		t.Fatalf("%v %q", err, o)
	}
	if fi, _ := os.Stat(f.path("opt/alerts.d/backup-ping")); fi == nil || fi.Mode().Perm() != 0o600 {
		t.Errorf("mode %v", fi)
	}
	if st := f.state(); st["_bp.upto"] != "" || st["_bp.err"] != "" || st["_sil.all"] != "99" {
		t.Errorf("a new URL starts fresh, the rest stays: %v", st)
	}
	set("off\n")
	if fsinfo.ExistsNoFollow(f.path("opt/alerts.d/backup-ping")) {
		t.Errorf("not removed")
	}
	w.Env.EUID = 1000
	if _, err := set("off\n"); err == nil {
		t.Errorf("not root: no error")
	}
}

func TestDoctorWarnsWithoutHeartbeat(t *testing.T) {
	f := newFakeHost(t)
	w := f.watch()
	doctor := func() string {
		o, _ := do(func(o *out.Writer) error { w.Doctor(context.Background(), o); return nil })
		return o
	}
	const row = "check\twarn\theartbeat\tnone: if this server goes down, nothing tells you. " +
		"Let an outside service expect a call from it: tando alerts heartbeat\n"
	if o := doctor(); strings.Contains(o, "\theartbeat\t") {
		t.Errorf("a server without apps is not nagged: %q", o)
	}
	f.app("blog")
	if o := doctor(); !strings.Contains(o, row) {
		t.Errorf("no warning with an app and no heartbeat: %q", o)
	}
	show, _ := do(func(o *out.Writer) error { return w.Show(context.Background(), o, nil) })
	if !strings.Contains(show, "apps\t1\n") {
		t.Errorf("show lacks the apps row: %q", show)
	}
	f.write("opt/alerts.d/heartbeat", "url=https://hc.example/ping/x\n")
	if o := doctor(); strings.Contains(o, "\twarn\theartbeat\t") {
		t.Errorf("the warning stays after a heartbeat was set: %q", o)
	}
}
