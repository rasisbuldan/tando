package logs

import (
	"context"
	"os"
	"regexp"
	"strings"
	"testing"

	"tando/srv/internal/fsinfo"
	"tando/srv/internal/out"
)

func TestValid(t *testing.T) {
	for kv, want := range map[string]bool{
		"log_max=16M": true, "log_max=3M": false, "log_max=4096K": true, "log_max=1234567M": false, "log_max=16m": false,
		"journal_max=2G": true, "request_log_max=auto": false, "log_keep=1h": true, "log_keep=0d": false, "log_keep=09d": true,
		"log_keep=8760h": true, "log_keep=87600h": false, "log_keep=521w": true, "log_keep=522w": false, "log_keep=1y": false, "access_keep_for=2d": true,
		"log_rate=off": true, "log_rate=5000/30s": true, "log_rate=0/30s": false, "log_rate=0500/030s": true, "log_rate=5/s": false,
		"access_log=on": true, "access_log=yes": false, "access_size=1": true, "access_size=0": false, "access_size=1000": false,
		"access_keep=0": true, "access_keep=100": false, "bogus=1": false, "log_max=": false, "log_keep=": false,
	} {
		k, v, _ := strings.Cut(kv, "=")
		if got := Valid(k, v); got != want {
			t.Errorf("Valid(%s) = %v", kv, got)
		}
	}
	for v, want := range map[string]string{"08": "8", "09d": "9d", "0500/030s": "500/30s", "016M": "16M", "off": "off"} {
		if got := norm(v); got != want {
			t.Errorf("norm(%s) = %s", v, got)
		}
	}
	wantErr(t, CheckValue("log_keep", "1y"), "bad value for log_keep: 1y")
	wantErr(t, CheckValue("", ""), "bad value for ?: ")
}

func TestSettingAndRoll(t *testing.T) {
	h := newHost(t)
	h.app("ab", "log_max=64M", "log_keep=bad")
	h.write("opt/logs.conf", "log_keep=09d\nlog_rate=0500/030s\n")
	a, err := h.l.app("ab")
	if err != nil {
		t.Fatal(err)
	}
	if a.setting("log_max") != "64M" || a.setting("log_keep") != "9d" || a.setting("log_rate") != "500/30s" ||
		a.setting("access_keep_for") != "9d" || a.setting("request_log_max") != "16M" || a.setting("access_log") != "on" {
		t.Fatalf("settings: %s %s %s %s %s", a.setting("log_max"), a.setting("log_keep"), a.setting("log_rate"),
			a.setting("access_keep_for"), a.setting("request_log_max"))
	}
	if a.settingSrc("log_max") != "app" || a.settingSrc("log_keep") != "host" || a.settingSrc("journal_max") != "auto" {
		t.Fatal("setting sources")
	}
	for conf, want := range map[string]roll{"request_log_max=256M": {32, 7, 32 << 23}, "request_log_max=8M": {1, 7, 8 << 20},
		"request_log_max=4M": {1, 3, 4 << 20}, "request_log_max=2G": {32, 63, 32 * 64 << 20}} {
		h.app("bb", conf)
		b, _ := h.l.app("bb")
		if r := b.roll(); r != want {
			t.Errorf("%s: %+v, want %+v", conf, r, want)
		}
	}
	h.write("opt/logs.conf", "access_size=1\naccess_keep=02\n")
	b, _ := h.l.app("bb")
	if r := b.roll(); r != (roll{1, 2, 3 << 20}) {
		t.Fatalf("host access_size/access_keep win: %+v", r)
	}
	if fs := h.l.fairShare(); !regexp.MustCompile(`^([0-9]+M|2G)$`).MatchString(fs) {
		t.Fatal(fs)
	}
	_, err = h.l.app("../x")
	wantErr(t, err, "invalid app name")
	_, err = h.l.app("nope")
	wantErr(t, err, "no such app: nope")
}

func TestAppSetup(t *testing.T) {
	h := newHost(t)
	h.app("hello", "log_max=16M", "log_keep=1h", "log_rate=off")
	h.cmd = func(argv []string) (string, error) { return "", nil } // every journald instance is active
	if _, err := h.rows(func(w *out.Writer) error { return h.l.AppSetup(context.Background(), "hello", w) }); err != nil {
		t.Fatal(err)
	}
	want := `# written by tando-logs for app hello: its own journal, capped (tando.conf log_max, log_keep)
# circular: when the files reach SystemMaxUse, journald deletes the oldest to make room
[Journal]
Storage=persistent
SystemMaxUse=16M
RuntimeMaxUse=8M
MaxRetentionSec=1h
MaxFileSec=15min
Compress=yes
RateLimitIntervalSec=0
`
	if got := h.read("etc/systemd/journald@tando-hello.conf"); got != want {
		t.Fatalf("namespace config:\n%s", got)
	}
	if got := strings.Join(h.calls[len(h.calls)-1], " "); got != "journalctl -q --namespace=tando-hello --vacuum-size=16M --vacuum-time=1h" {
		t.Fatalf("vacuum: %s", got)
	}
	fi, err := os.Stat(h.path("log/tando/hello"))
	if err != nil || fi.Mode()&os.ModePerm != 0o750 || fi.Mode()&os.ModeSetgid == 0 {
		t.Fatalf("request log dir: %v %v", fi.Mode(), err)
	}
	if fi, err := os.Stat(h.path("log/tando/hello/access.log")); err != nil || fi.Mode().Perm() != 0o640 {
		t.Fatalf("access.log: %v", err)
	}
	// unchanged: no restart of its journald
	n := len(h.calls)
	h.rows(func(w *out.Writer) error { return h.l.AppSetup(context.Background(), "hello", w) })
	if len(h.calls) != n {
		t.Fatalf("an unchanged config restarted journald: %v", h.calls[n:])
	}
	// rate limit and a day of retention
	h.app("hello", "log_keep=2d", "log_rate=0200/010s")
	h.rows(func(w *out.Writer) error { return h.l.AppSetup(context.Background(), "hello", w) })
	if got := h.read("etc/systemd/journald@tando-hello.conf"); !strings.Contains(got, "MaxRetentionSec=48h\nMaxFileSec=720min\n") ||
		!strings.HasSuffix(got, "RateLimitIntervalSec=10s\nRateLimitBurst=200\n") {
		t.Fatal(got)
	}
	h.l.Env.EUID = 1000
	_, err = h.rows(func(w *out.Writer) error { return h.l.AppSetup(context.Background(), "hello", w) })
	wantErr(t, err, "this needs root (sudo)")
}

func TestHostSetup(t *testing.T) {
	h := newHost(t)
	h.app("ab")
	h.write("opt/logs.conf", "zz=kept=\naccess_size=2\n")
	o, err := h.rows(func(w *out.Writer) error {
		return h.l.HostSetup(context.Background(), []string{"journal_max=128M", "log_keep=08d"}, w)
	})
	if err != nil || o != "ok=1\n" {
		t.Fatal(o, err)
	}
	if got := h.read("opt/logs.conf"); got != "access_size=2\njournal_max=128M\nlog_keep=8d\nzz=kept=\n" {
		t.Fatalf("logs.conf: %q", got)
	}
	if got := h.read("etc/systemd/journald.conf.d/tando.conf"); got != "# written by tando-logs: cap of the main journal (apps log into their own namespaces)\n[Journal]\nSystemMaxUse=128M\nRuntimeMaxUse=64M\n" {
		t.Fatal(got)
	}
	if len(h.argvs("systemctl")) == 0 || h.argvs("systemctl")[0] != "systemctl restart systemd-journald" {
		t.Fatal(h.argvs("systemctl"))
	}
	if !fsinfo.RegularFollow(h.path("etc/systemd/journald@tando-ab.conf")) || !fsinfo.RegularFollow(h.path("log/tando/audit.log")) {
		t.Fatal("app setup or audit log missing")
	}
	_, err = h.rows(func(w *out.Writer) error { return h.l.HostSetup(context.Background(), []string{"log_keep=1y"}, w) })
	wantErr(t, err, "bad log setting: log_keep=1y")
	_, err = h.rows(func(w *out.Writer) error { return h.l.HostSetup(context.Background(), []string{"novalue"}, w) })
	wantErr(t, err, "bad log setting: novalue")
}

func TestCaddyLog(t *testing.T) {
	h := newHost(t)
	h.app("keep", "log_keep=1h", "request_log_max=8M")
	ver := "v2.6.2 h1:x="
	h.cmd = func(argv []string) (string, error) { return ver + "\n", nil }
	block := func() string {
		var b strings.Builder
		if err := h.l.CaddyLog(context.Background(), "keep", &b); err != nil {
			t.Fatal(err)
		}
		return b.String()
	}
	b := block()
	for _, s := range []string{"\t\toutput file " + h.path("log/tando/keep") + "/./access.log {\n\t\t\troll_size 1MiB\n",
		"\t\t\troll_keep 7\n\t\t\troll_keep_for 1h\n", "header X-Tando-Probe none-", "\t\t\t\trequest>uri regexp \\?.*$ ?-\n"} {
		if !strings.Contains(b, s) {
			t.Fatalf("missing %q in\n%s", s, b)
		}
	}
	if strings.Contains(b, "mode 0640") || h.read("cache/keep.reqlog") != "1 1,7,1\n" {
		t.Fatalf("2.6.2 has no mode; record %q", h.read("cache/keep.reqlog"))
	}
	ver = "v2.11.9 h1:y="
	h.write("opt/probe.header", "X-Tando-Probe: "+strings.Repeat("ab", 16)+"\n")
	b = block()
	if !strings.Contains(b, "{\n\t\t\tmode 0640\n") || !strings.Contains(b, "X-Tando-Probe "+strings.Repeat("ab", 16)+"\n") ||
		!strings.Contains(b, "/./access.log") {
		t.Fatal(b)
	}
	// a changed rotation alternates the name (a new log writer in Caddy, no restart)
	h.write("opt/logs.conf", "access_size=2\n")
	if b = block(); strings.Contains(b, "/./access.log") || h.read("cache/keep.reqlog") != "0 2,7,1\n" {
		t.Fatalf("%q", h.read("cache/keep.reqlog"))
	}
	h.app("keep", "access_log=off")
	if b = block(); b != "" {
		t.Fatal(b)
	}
}

func TestAppRemoveAndUnitProps(t *testing.T) {
	h := newHost(t)
	h.app("gone")
	h.write("etc/systemd/journald@tando-gone.conf", "x")
	h.write("log/journal/"+machineID+".tando-gone/system.journal", "x")
	h.write("log/journal/"+machineID+".tando-gone-2/system.journal", "x")
	h.write("log/tando/gone/access.log", "x")
	h.write("cache/gone.stats", "x")
	o, err := h.rows(func(w *out.Writer) error { return h.l.AppRemove(context.Background(), "gone", w) })
	if err != nil || o != "removed=1\n" || fsinfo.RegularFollow(h.path("etc/systemd/journald@tando-gone.conf")) ||
		fsinfo.DirFollow(h.path("log/journal/"+machineID+".tando-gone")) || !fsinfo.DirFollow(h.path("log/journal/"+machineID+".tando-gone-2")) ||
		fsinfo.DirFollow(h.path("log/tando/gone")) || fsinfo.RegularFollow(h.path("cache/gone.stats")) {
		t.Fatal(o, err)
	}
	var b strings.Builder
	if err := h.l.UnitProps("gone", &b); err != nil || b.String() != "LogNamespace=tando-gone\n" {
		t.Fatal(b.String(), err)
	}
	_, err = h.rows(func(w *out.Writer) error { return h.l.AppRemove(context.Background(), "a;b", w) })
	wantErr(t, err, "invalid app name")
}
