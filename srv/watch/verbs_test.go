package watch

import (
	"context"
	"os"
	"strings"
	"testing"

	"tando/srv/internal/decimal"
	"tando/srv/internal/fsinfo"
	"tando/srv/internal/out"
)

func TestSetValidation(t *testing.T) {
	for _, tt := range []struct{ in, err string }{
		{"novalue\n", "expected key=value: novalue"},
		{"disk_pct=9\x01\n", "control characters in disk_pct"},
		{"Hog.mem_pct=5\n", "bad app name in Hog.mem_pct"},
		{"load=maybe\n", "load must be on or off"},
		{"hog.caddy=off\n", "caddy is a host check: set it without an app"},
		{"hog.name=x\n", "bad name"},
		{"name=has space\n", "bad name"},
		{"notify_reboot=sometimes\n", "notify_reboot must be yes or no"},
		{"include_log_lines=yes\n", "include_log_lines must be on or off"},
		{"mem_pct=1234567\n", "mem_pct must be a whole number"},
		{"bogus=1\n", "unknown setting: bogus (see tando alerts set)"},
	} {
		f := newFakeHost(t)
		w := f.watch()
		_, err := do(func(o *out.Writer) error { return w.Set(o, strings.NewReader(tt.in)) })
		if err == nil || err.Error() != tt.err {
			t.Errorf("set %q: %v, want %q", tt.in, err, tt.err)
		}
	}
	f := newFakeHost(t)
	w := f.watch()
	o, err := do(func(o *out.Writer) error {
		return w.Set(o, strings.NewReader("hog.health_fails=02\nload=off\nhog.disk=off\nname=web-1\nmem_pct=95\nhog.memory=off\n"))
	})
	if err != nil || o != "ok=1\n" {
		t.Fatalf("set: %v %q", err, o)
	}
	do(func(o *out.Writer) error { return w.Set(o, strings.NewReader("mem_pct=\n")) })
	b, _ := os.ReadFile(f.path("opt/alerts.conf"))
	want := confHeader + "hog.disk=off\nhog.health_fails=2\nhog.memory=off\nload=off\nname=web-1\n"
	if string(b) != want {
		t.Errorf("alerts.conf:\n%s\nwant\n%s", b, want)
	}
}

func TestNotifierAddRm(t *testing.T) {
	for _, tt := range []struct{ args, in, err string }{
		{"Bad webhook", "url=http://x/y\n", "bad notifier name (a-z, 0-9, -; up to 20)"},
		{"n webhook", "url=http://x/a b\n", "bad characters in url"},
		{"n webhook", "url=ftp://x/y\n", "url must be an http(s) URL"},
		{"n webhook", "", "webhook needs url"},
		{"n ntfy", "", "ntfy needs url (https://ntfy.sh/<topic>)"},
		{"n telegram", "token=abcd:ef\n", "telegram needs token and chat"},
		{"n telegram", "token=a\n", "bad token"},
		{"n telegram", "chat=x\n", "bad chat id"},
		{"n email", "to=nobody\n", "bad address in to"},
		{"n webhook", "type=x\n", "unknown field: type"},
		{"n pager", "", "type must be webhook, slack, telegram, ntfy or email"},
	} {
		f := newFakeHost(t)
		w := f.watch()
		_, err := do(func(o *out.Writer) error {
			return w.NotifierAdd(o, strings.Fields(tt.args), strings.NewReader(tt.in))
		})
		if err == nil || err.Error() != tt.err {
			t.Errorf("notifier-add %s %q: %v, want %q", tt.args, tt.in, err, tt.err)
		}
	}
	f := newFakeHost(t)
	w := f.watch()
	f.write("lib/watch/state", "_nf.hook.fails=3\n_nf.hook.next=9\nhog.nr=0\n")
	o, err := do(func(o *out.Writer) error {
		return w.NotifierAdd(o, []string{"hook", "webhook"}, strings.NewReader("url=http://127.0.0.1:9999/eq/S3CR3Teq?k=\n"))
	})
	if err != nil || o != "ok=1\n" {
		t.Fatalf("add: %v %q", err, o)
	}
	fi, _ := os.Stat(f.path("opt/alerts.d/notify-hook"))
	b, _ := os.ReadFile(f.path("opt/alerts.d/notify-hook"))
	if fi.Mode().Perm() != 0o600 || string(b) != "type=webhook\nurl=http://127.0.0.1:9999/eq/S3CR3Teq?k=\n" {
		t.Errorf("notify-hook %v %q", fi.Mode(), b)
	}
	if st := f.state(); len(st) != 1 || !fsinfo.DirFollow(f.path("lib/watch/out/hook")) {
		t.Errorf("state %v", st)
	}
	if _, err := do(func(o *out.Writer) error { return w.NotifierRm(o, []string{"nope"}) }); err == nil || err.Error() != "no such notifier: nope" {
		t.Errorf("rm nope: %v", err)
	}
	if o, err := do(func(o *out.Writer) error { return w.NotifierRm(o, []string{"hook"}) }); err != nil || o != "ok=1\n" ||
		fsinfo.ExistsNoFollow(f.path("opt/alerts.d/notify-hook")) || fsinfo.ExistsNoFollow(f.path("lib/watch/out/hook")) {
		t.Errorf("rm: %v %q", err, o)
	}
}

func TestHeartbeatVerb(t *testing.T) {
	f := newFakeHost(t)
	w := f.watch()
	for _, in := range []string{"url=ftp://x\n", "url=http://x/a\"b\n", "http://x\n", "url=http://x/y"} {
		if _, err := do(func(o *out.Writer) error { return w.Heartbeat(o, strings.NewReader(in)) }); err == nil ||
			err.Error() != "the heartbeat must be an http(s) URL" {
			t.Errorf("%q: %v", in, err)
		}
	}
	if o, err := do(func(o *out.Writer) error {
		return w.Heartbeat(o, strings.NewReader("url=https://hc.example/ping/S3CR3T\n"))
	}); err != nil || o != "ok=1\n" {
		t.Fatalf("%v %q", err, o)
	}
	if fi, _ := os.Stat(f.path("opt/alerts.d/heartbeat")); fi.Mode().Perm() != 0o600 {
		t.Errorf("mode %v", fi.Mode())
	}
	do(func(o *out.Writer) error { return w.Heartbeat(o, strings.NewReader("off\n")) })
	if fsinfo.ExistsNoFollow(f.path("opt/alerts.d/heartbeat")) {
		t.Errorf("not removed")
	}
}

func TestReadVerbs(t *testing.T) {
	f := newFakeHost(t)
	f.app("hog")
	w := f.watch()
	now := f.now.Unix()
	f.write("lib/watch/state", "hog.health.st=firing\nhog.health.since=100\nhog.health.det=unhealthy: x\thid\nhog.health.ns=firing\n"+
		"_host.disk.st=pending\n_host.disk.n=1\n_sil.hog="+decimal.Itoa(now+60)+"\n_nf.hook.fails=2\n_nf.hook.err=HTTP 500\n_nf.hook.since="+decimal.Itoa(now-720)+"\n")
	f.write("lib/watch/history.tsv", "1\tfire\thog\thealth\tunhealthy: x\n2\tresolve\thost\tdisk\tafter 1m\n")
	f.notifier("hook", "type=webhook\nurl=https://u:p@hooks.example.com/S3CR3T\n")
	f.notifier("tg", "type=telegram\ntoken=a:b\nchat=-100123\n")
	f.write("lib/watch/out/hook/1.1", "firing\thog\thealth\tx\t1\n")
	f.write("opt/alerts.conf", "hog.health_fails=1\nmem_pct=x\n")
	f.write("units/tando-watch.timer", "x")
	f.units["tando-watch.timer"] = map[string]string{"ActiveState": "active"}
	f.units["tando-watch.service"] = map[string]string{"Result": "success", "ExecMainStartTimestampMonotonic": "99990000000"}
	o, err := do(func(o *out.Writer) error { return w.Show(context.Background(), o, nil) })
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"run\tok\talerts\tchecks ran 2m 52s ago; 1 firing\n", // uptime 100000 s, last start at 99990 s... (see setUptime)
		"alert\thog\thealth\tfiring\t100\tunhealthy: x?hid\tfiring\t1\t0\t-\n",
		"alert\thost\tdisk\tpending\t-\t-\tok\t0\t0\t1\n",
		"silence\thog\t" + decimal.Itoa(now+60) + "\n",
		"notifier\thook\twebhook\thttps://hooks.example.com/…\t-\t2\t1\t-\tHTTP 500\t0\n",
		"notifier\ttg\ttelegram\tchat …123\t-\t0\t0\t-\t-\t0\n",
		"hist\t1\tfire\thog\thealth\tunhealthy: x\n",
		"conf\tmem_pct\t90\n", "conf\tname\t-\n", "conf\thog.health_fails\t1\n",
	} {
		if !strings.Contains(o, want) && !strings.HasPrefix(want, "run") {
			t.Errorf("show lacks %q:\n%s", want, o)
		}
	}
	if strings.Contains(o, "S3CR3T") {
		t.Errorf("a secret in show")
	}
	o, _ = do(func(o *out.Writer) error { w.Brief(o, []string{"host"}); return nil })
	if o != "alert\thost\tdisk\tpending\t-\t-\n" {
		t.Errorf("brief host: %q", o)
	}
	o, _ = do(func(o *out.Writer) error { return w.History(o, []string{"1"}) })
	if o != "hist\t2\tresolve\thost\tdisk\tafter 1m\n" {
		t.Errorf("history 1: %q", o)
	}
	if _, err := do(func(o *out.Writer) error { return w.History(o, []string{"x"}) }); err == nil || err.Error() != "bad count" {
		t.Errorf("history x: %v", err)
	}
	o, _ = do(func(o *out.Writer) error { w.Doctor(context.Background(), o); return nil })
	if !strings.Contains(o, "check\twarn\tnotifier hook\tfailing for 12m 0s: HTTP 500; messages wait in its queue (tando alerts test hook)\n") ||
		!strings.HasSuffix(o, "check\tok\tnotifiers\t2, no heartbeat (tando alerts heartbeat)\n") {
		t.Errorf("doctor: %q", o)
	}
	w.Env.EUID = 1000
	for _, fn := range []func(o *out.Writer) error{
		func(o *out.Writer) error { return w.Show(context.Background(), o, nil) },
		func(o *out.Writer) error { return w.History(o, nil) },
		func(o *out.Writer) error { return w.Run(context.Background()) },
	} {
		if _, err := do(fn); err == nil || err.Error() != "this needs root (sudo)" {
			t.Errorf("without root: %v", err)
		}
	}
}

func TestHealthVerbAndForget(t *testing.T) {
	f := newFakeHost(t)
	f.app("hog")
	w := f.watch()
	now := f.now.Unix()
	var b strings.Builder
	for i := int64(0); i < 60; i++ { // the last hour: 58 ok minutes of 10-30 ms, one down, one held
		switch i {
		case 10:
			b.WriteString(decimal.Itoa(now-3600+i*60) + " down\n")
		case 20:
			b.WriteString(decimal.Itoa(now-3600+i*60) + " hold\n")
		default:
			b.WriteString(decimal.Itoa(now-3600+i*60) + " ok " + decimal.Itoa(10+i%3*10) + "\n")
		}
	}
	f.write("lib/watch/probe/hog", b.String())
	f.write("lib/watch/incidents/hog.tsv", decimal.Itoa(now-3000)+"\t"+decimal.Itoa(now-2900)+"\tdown\tnot running\n"+decimal.Itoa(now-100)+"\t-\thealth\tslow\n"+
		decimal.Itoa(now-50)+"\t"+decimal.Itoa(now-50)+"\trestart\tunhealthy\n")
	f.write("lib/watch/tail/hog", "1700000000\tfatal: crashing\n")
	f.write("lib/watch/state", "hog.health.st=firing\n")
	o, err := do(func(o *out.Writer) error { return w.Health(o, []string{"hog"}) })
	if err != nil {
		t.Fatal(err)
	}
	ls := strings.Split(strings.TrimSuffix(o, "\n"), "\n")
	hours := strings.Repeat("-,", 23) + "20"
	want := []string{
		"up\thog\t9830\t9830\t59\t59\t2\t20\t30\t" + hours + "\tok\t30\thealth",
		"inc\thog\t" + decimal.Itoa(now-50) + "\t" + decimal.Itoa(now-50) + "\trestart\tunhealthy",
		"inc\thog\t" + decimal.Itoa(now-100) + "\t-\thealth\tslow",
		"inc\thog\t" + decimal.Itoa(now-3000) + "\t" + decimal.Itoa(now-2900) + "\tdown\tnot running",
		"tail\thog\t1700000000\tfatal: crashing",
	}
	if strings.Join(ls, "\n") != strings.Join(want, "\n") {
		t.Errorf("health hog:\n%s\nwant\n%s", strings.Join(ls, "\n"), strings.Join(want, "\n"))
	}
	if _, err := do(func(o *out.Writer) error { return w.Health(o, []string{"nope"}) }); err == nil || err.Error() != "no such app: nope" {
		t.Errorf("health nope: %v", err)
	}
	f.write("run/vstate", "win.hog=1:2:3:4\nlast=5\ndumb.hog=9\n")
	f.write("lib/watch/state", "hog.health.st=firing\nhogx.health.st=firing\n")
	if o, err := do(func(o *out.Writer) error { return w.Forget(o, []string{"hog"}) }); err != nil || o != "ok=1\n" {
		t.Fatalf("forget: %v %q", err, o)
	}
	if st := f.state(); len(st) != 1 || st["hogx.health.st"] != "firing" || len(f.vstate()) != 1 || fsinfo.ExistsNoFollow(f.path("lib/watch/probe/hog")) {
		t.Errorf("after forget: %v %v", st, f.vstate())
	}
}

func TestTestVerb(t *testing.T) {
	f := newFakeHost(t)
	w := f.watch()
	f.notifier("hook", "type=webhook\nurl=http://h/hook\n")
	f.write("lib/watch/state", "_nf.hook.next=9999999999\n")
	o, err := do(func(o *out.Writer) error { return w.TestSend(context.Background(), o, nil) })
	want := "sent\ttando testhost: test\tThis is a test message from tando alerts: delivery works.\ntest\thook\tok\tHTTP 200\n"
	if err != nil || o != want {
		t.Errorf("test: %v %q", err, o)
	}
	if f.st("_nf.hook.next") != "" {
		t.Errorf("backoff not ended")
	}
	body := f.sentBodies()[0]
	if !strings.Contains(body, `"events":[{"state":"test","app":"host","check":"test","detail":"this is a test message from tando alerts; delivery works","since":`) {
		t.Errorf("body %s", body)
	}
	o, err = do(func(o *out.Writer) error { return w.TestSend(context.Background(), o, []string{"nope"}) })
	if err == nil || err.Error() != "no such notifier: nope" || !strings.HasPrefix(o, "sent\t") {
		t.Errorf("test nope: %v %q", err, o)
	}
	os.Remove(f.path("opt/alerts.d/notify-hook"))
	if o, _ := do(func(o *out.Writer) error { return w.TestSend(context.Background(), o, nil) }); !strings.HasSuffix(o, "none=1\n") {
		t.Errorf("none: %q", o)
	}
}

// The units are the shell version's byte for byte: an upgraded host is not reloaded.
func TestUnits(t *testing.T) {
	want := `[Unit]
Description=tando: alert checks
After=network.target caddy.service
StartLimitIntervalSec=0

[Service]
Type=oneshot
# each run: the metrics sample (tando-metrics sample), recover-all when an activation died or an
# app is down, the checks; through tandod when it runs (tando-watch run asks it)
ExecStart=/opt/tando/bin/tando-watch run
Nice=10
TimeoutStartSec=300
RuntimeDirectory=tando-watch
RuntimeDirectoryMode=0700
RuntimeDirectoryPreserve=yes
UMask=0022
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=yes
NoNewPrivileges=yes
MemoryMax=64M
LogLevelMax=notice
`
	if got := fallbackUnit("/opt/tando/bin/tando-watch"); !strings.Contains(got, "\nConditionPathExists=!/run/tandod/active\n") {
		t.Errorf("fallback unit:\n%s", got)
	}
	if got := serviceUnit("/opt/tando", "/opt/tando/bin/tando-watch"); got != want {
		t.Errorf("service unit:\n%s", got)
	}
	f := newFakeHost(t)
	w := f.watch()
	if o, err := do(func(o *out.Writer) error { return w.Install(context.Background(), o) }); err != nil || o != "ok=1\n" {
		t.Fatalf("install: %v %q", err, o)
	}
	if len(f.called("systemctl daemon-reload")) != 1 || len(f.called("systemctl enable -q --now tando-watch.timer")) != 1 ||
		len(f.called("systemctl restart tandod.service")) != 0 {
		t.Errorf("calls %v", f.calls)
	}
	f.reset()
	do(func(o *out.Writer) error { return w.Install(context.Background(), o) })
	if len(f.called("systemctl daemon-reload")) != 0 {
		t.Errorf("reloaded without a change")
	}
	// with tandod installed: its unit written, enabled and started (it did not run); the process
	// then runs the installed file (/proc/<pid>/exe)
	f.write("opt/bin/tandod", "x")
	os.Chmod(f.path("opt/bin/tandod"), 0o755)
	os.MkdirAll(f.path("proc/777"), 0o755)
	os.Symlink(f.path("opt/bin/tandod"), f.path("proc/777/exe"))
	f.units["tandod.service"] = map[string]string{"ActiveState": "inactive", "MainPID": "0", "NextPID": "777"}
	f.reset()
	if _, err := do(func(o *out.Writer) error { return w.Install(context.Background(), o) }); err != nil {
		t.Fatal(err)
	}
	if !fsinfo.ExistsNoFollow(f.path("units/tandod.service")) || len(f.called("systemctl start tandod.service")) != 1 ||
		len(f.called("systemctl daemon-reload")) != 1 {
		t.Errorf("tandod: %v", f.calls)
	}
	// running the installed file, unit unchanged: left alone
	f.reset()
	do(func(o *out.Writer) error { return w.Install(context.Background(), o) })
	if len(f.called("systemctl try-restart")) != 0 || len(f.called("systemctl start tandod")) != 0 {
		t.Errorf("restarted a daemon that runs the installed binary: %v", f.calls)
	}
	// an older tando's unit (MemoryMax=64M: its page cache re-read the journals every minute):
	// rewritten with 160M, systemd reloaded, tandod restarted
	f.write("units/tandod.service", strings.Replace(daemonUnit(f.path("opt")), "\nMemoryMax=160M\n", "\nMemoryMax=64M\n", 1))
	f.reset()
	do(func(o *out.Writer) error { return w.Install(context.Background(), o) })
	if b, _ := os.ReadFile(f.path("units/tandod.service")); !strings.Contains(string(b), "\nMemoryMax=160M\n") ||
		len(f.called("systemctl daemon-reload")) != 1 || len(f.called("systemctl try-restart tandod.service")) != 1 {
		t.Errorf("an old unit with 64M: %v\n%s", f.calls, b)
	}
	// a new binary installed (another file): try-restart, and the new process runs it
	os.Remove(f.path("opt/bin/tandod"))
	f.write("opt/bin/tandod", "y")
	os.Chmod(f.path("opt/bin/tandod"), 0o755)
	os.MkdirAll(f.path("proc/778"), 0o755)
	os.Symlink(f.path("opt/bin/tandod"), f.path("proc/778/exe"))
	os.Remove(f.path("proc/777/exe"))
	f.write("proc/777/exe", "the old file") // (what the old process still runs)
	f.units["tandod.service"]["NextPID"] = "778"
	f.reset()
	if _, err := do(func(o *out.Writer) error { return w.Install(context.Background(), o) }); err != nil {
		t.Fatal(err)
	}
	if len(f.called("systemctl try-restart tandod.service")) != 1 {
		t.Errorf("not restarted after an upgrade: %v", f.calls)
	}
	for p, m := range map[string]os.FileMode{"lib/watch/state": 0o600, "lib/watch/history.tsv": 0o600, "opt/alerts.d": 0o700, "opt/alerts.conf": 0o644} {
		if fi, err := os.Stat(f.path(p)); err != nil || fi.Mode().Perm() != m {
			t.Errorf("%s: %v", p, fi.Mode())
		}
	}
}
