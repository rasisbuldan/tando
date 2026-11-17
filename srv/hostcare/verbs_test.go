package hostcare

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"tando/srv/internal/fsinfo"
	"tando/srv/internal/out"
	"tando/srv/internal/out/outtest"
)

var ctx = context.Background()

func TestCheckBaseline(t *testing.T) {
	f := newFake(t)
	fs, as := f.check()
	// the captured server: 2 security updates (just seen), python open on 8765, passwords on
	if fs["updates.security"].State != "warn" || !strings.Contains(fs["updates.security"].Detail, "libc6") || !fs["updates.security"].Auto {
		t.Errorf("security: %+v", fs["updates.security"])
	}
	if x := fs["security.exposed.tcp-8765"]; x.State != "fail" || !strings.Contains(x.Detail, "python3") || !strings.Contains(x.Fix, "allow_ports=tcp/8765") {
		t.Errorf("exposed: %+v", x)
	}
	if x := fs["security.listening"]; !strings.Contains(x.Detail, "22/tcp ssh") {
		t.Errorf("listening: %+v", x)
	}
	if x := fs["security.ssh.login"]; x.State != "warn" || !strings.Contains(x.Detail, "vmadmin 2") {
		t.Errorf("ssh: %+v", x)
	}
	if x := fs["updates.eol"]; x.State != "ok" || !strings.Contains(x.Detail, "2029-05-31") {
		t.Errorf("eol: %+v", x)
	}
	if x := fs["updates.auto"]; x.State != "ok" || !strings.Contains(x.Detail, "Ubuntu's default") {
		t.Errorf("auto: %+v", x)
	}
	if x := fs["health.clock"]; x.State != "ok" || !strings.Contains(x.Detail, "timesyncd") {
		t.Errorf("clock: %+v", x)
	}
	for _, c := range AlertChecks {
		a, ok := as[c]
		if !ok {
			t.Errorf("no alert row for %s", c)
		}
		want := "ok"
		if c == "exposed" || c == "ssh" {
			want = "bad"
		}
		if a.State != want {
			t.Errorf("alert %s: %+v", c, a)
		}
	}
	if as["exposed"].Priority != "high" || as["ssh"].Priority != "low" {
		t.Error("priorities")
	}
	// the files: summary and state root 600 in a root 700 directory, no temp file left
	for p, m := range map[string]os.FileMode{f.h.dir(): 0o700, f.h.SummaryPath(): 0o600, f.h.statePath(): 0o600, f.h.aptPath(): 0o600} {
		if fi, err := os.Stat(p); err != nil || fi.Mode().Perm() != m {
			t.Errorf("%s: %v %v", p, fi, err)
		}
	}
	ents, _ := os.ReadDir(f.h.dir())
	for _, e := range ents {
		if strings.Contains(e.Name(), "tmp") {
			t.Errorf("left over: %s", e.Name())
		}
	}
	if todo, fail, _, at, ok := Brief(f.h.SummaryPath()); !ok || todo == "0" || fail == "0" || at != i64(f.now.Unix()) {
		t.Errorf("brief: %s %s %s %v", todo, fail, at, ok)
	}
	// apt is not asked again within apt_hours (the cache), but after dpkg changed
	f.reset()
	f.verb(func(o *out.Writer) error { return f.h.Check(ctx, o, nil) })
	if f.called("apt-get -s") || f.called("needrestart") {
		t.Error("apt was asked again within apt_hours")
	}
	f.advance(time.Minute)
	os.Chtimes(f.p("fs/var/lib/dpkg/status"), f.now, f.now)
	f.verb(func(o *out.Writer) error { return f.h.Check(ctx, o, nil) })
	if !f.called("apt-get -s") {
		t.Error("dpkg changed, apt was not asked")
	}
}

func TestThresholds(t *testing.T) {
	f := newFake(t)
	f.check()
	// security updates: warn at first, fail (and the updates alert) after updates_days
	f.advance(3*24*time.Hour + time.Minute)
	fs, as := f.check()
	if fs["updates.security"].State != "fail" || as["updates"].State != "bad" || !strings.Contains(as["updates"].Detail, "tando host update") {
		t.Errorf("updates after 3 days: %+v %+v", fs["updates.security"], as["updates"])
	}
	f.write("root/hostcare.conf", "updates_days=5\nexposed=off\n")
	fs, as = f.check()
	if fs["updates.security"].State != "warn" || as["updates"].State != "ok" || as["exposed"].State != "off" {
		t.Errorf("updates_days=5: %+v %+v %+v", fs["updates.security"], as["updates"], as["exposed"])
	}
	// the updates are installed: the finding and the first sightings go
	f.answer["apt-get -s"] = "Reading package lists...\n0 upgraded\n"
	fs, as = f.check()
	if fs["updates.security"].State != "ok" || as["updates"].State != "ok" {
		t.Errorf("installed: %+v", fs["updates.security"])
	}
	if st := loadState(f.h.statePath()); len(st.keys("sec.")) != 0 {
		t.Errorf("first sightings kept: %v", st.keys("sec."))
	}

	// reboot needed: warn, and after reboot_days the alert
	f.write("fs/run/reboot-required", "*** System restart required ***\n")
	f.write("fs/run/reboot-required.pkgs", "linux-image-6.8.0-52-generic\n")
	fs, as = f.check()
	if fs["updates.reboot"].State != "warn" || as["reboot"].State != "ok" || !fs["updates.reboot"].Auto {
		t.Errorf("reboot day 0: %+v", fs["updates.reboot"])
	}
	f.advance(7*24*time.Hour + time.Hour)
	fs, as = f.check()
	if fs["updates.reboot"].State != "fail" || as["reboot"].State != "bad" {
		t.Errorf("reboot day 7: %+v %+v", fs["updates.reboot"], as["reboot"])
	}

	// a failed unit; tando's own are the down check's
	f.answer["systemctl show -p SystemState"] = "SystemState=degraded\nNFailedUnits=2\nVirtualization=kvm\n"
	f.answer["systemctl list-units"] = "foo.service loaded failed failed Foo\ntando-shop.service loaded failed failed shop\n"
	fs, as = f.check()
	if fs["health.units"].State != "fail" || as["units"].State != "bad" || strings.Contains(as["units"].Detail, "tando-shop") {
		t.Errorf("units: %+v %+v", fs["health.units"], as["units"])
	}

	// a file system read-only; /boot full; I/O errors in the kernel log
	f.write("proc/mounts", "/dev/vda1 / ext4 rw 0 0\n/dev/vdb1 /srv ext4 ro,relatime 0 0\n/dev/vda2 /boot ext4 rw 0 0\n")
	os.MkdirAll(f.p("fs/srv"), 0o755)
	f.disks["/boot"] = fsinfo.FS{Blocks: 100, Free: 4, Avail: 4, Files: 100, FilesFree: 50, Unit: 1 << 20}
	f.answer["journalctl"] = string(fixture(t, "hand/journal.json"))
	f.now = time.Unix(1763280800, 0)
	fs, as = f.check()
	if fs["health.readonly"].State != "fail" || as["readonly"].State != "bad" || as["readonly"].Priority != "high" {
		t.Errorf("readonly: %+v %+v", fs["health.readonly"], as["readonly"])
	}
	if fs["health.disk.boot"].State != "fail" || as["boot"].State != "bad" || !fs["health.disk.boot"].Auto {
		t.Errorf("boot: %+v %+v", fs["health.disk.boot"], as["boot"])
	}
	if fs["health.ioerr"].State != "fail" || as["ioerr"].State != "bad" || !strings.Contains(as["ioerr"].Detail, "2 disk I/O errors") {
		t.Errorf("ioerr: %+v %+v", fs["health.ioerr"], as["ioerr"])
	}
	if fs["health.oom"].State != "warn" {
		t.Errorf("oom: %+v", fs["health.oom"])
	}
	if st := loadState(f.h.statePath()); st.get("jcursor") != "s=1;i=8" {
		t.Errorf("cursor: %q", st.get("jcursor"))
	}
	// the cursor is used next time; the events age out after 24 h
	f.answer["journalctl"] = ""
	f.reset()
	f.advance(25 * time.Hour)
	fs, as = f.check()
	if !f.called("journalctl --no-pager -q -o json --output-fields=MESSAGE,_TRANSPORT,SYSLOG_IDENTIFIER -n 5000 --after-cursor=s=1;i=8") {
		t.Error("cursor not used")
	}
	if fs["health.ioerr"].State != "ok" || as["ioerr"].State != "ok" {
		t.Errorf("ioerr after 24 h: %+v", fs["health.ioerr"])
	}

	// the clock: warn, then fail after clock_min; no time service at all fails at once
	f.synced = false
	fs, as = f.check()
	if fs["health.clock"].State != "warn" || as["clock"].State != "ok" {
		t.Errorf("clock new: %+v", fs["health.clock"])
	}
	f.advance(61 * time.Minute)
	fs, as = f.check()
	if fs["health.clock"].State != "fail" || as["clock"].State != "bad" {
		t.Errorf("clock 61 min: %+v", fs["health.clock"])
	}
}

func TestEOLAndFirewall(t *testing.T) {
	f := newFake(t)
	f.write("fs/etc/os-release", "ID=ubuntu\nVERSION_ID=\"25.10\"\nPRETTY_NAME=\"Ubuntu 25.10\"\n")
	fs, as := f.check()
	if fs["updates.eol"].State != "fail" || as["eol"].State != "bad" {
		t.Errorf("25.10: %+v %+v", fs["updates.eol"], as["eol"])
	}
	f.write("fs/etc/os-release", "ID=ubuntu\nVERSION_ID=\"26.10\"\nPRETTY_NAME=\"Ubuntu 26.10\"\n")
	fs, as = f.check()
	if fs["updates.eol"].State != "warn" || !strings.Contains(fs["updates.eol"].Detail, "unknown") || as["eol"].State != "ok" {
		t.Errorf("unknown release: %+v %+v", fs["updates.eol"], as["eol"])
	}
	f.write("fs/etc/os-release", "ID=ubuntu\nVERSION_ID=\"24.04\"\nPRETTY_NAME=\"Ubuntu 24.04\"\n")
	f.now = time.Date(2029, 4, 15, 0, 0, 0, 0, time.UTC)
	fs, as = f.check()
	if fs["updates.eol"].State != "warn" || as["eol"].State != "bad" {
		t.Errorf("within 60 days: %+v %+v", fs["updates.eol"], as["eol"])
	}
	// ufw active with default deny and no rule for 8765: blocked, not exposed
	f.write("fs/etc/ufw/ufw.conf", "ENABLED=yes\n")
	f.write("fs/etc/default/ufw", "DEFAULT_INPUT_POLICY=\"DROP\"\n")
	f.copy("hand/user.rules", "fs/etc/ufw/user.rules")
	f.answer["systemctl show -p ActiveState"] = f.unitStates(map[string]string{"ufw.service": "active", "systemd-timesyncd.service": "active"})
	fs, as = f.check()
	if fs["security.exposed.tcp-8765"].State != "ok" || as["exposed"].State != "ok" || fs["security.firewall"].State != "ok" ||
		!strings.Contains(fs["security.ssh.fails"].Detail, "ufw limit") {
		t.Errorf("ufw: %+v %+v %+v", fs["security.exposed.tcp-8765"], as["exposed"], fs["security.ssh.fails"])
	}
	// no ufw, nftables.conf drops by default: cannot tell, still reported, and it says so
	os.Remove(f.p("fs/etc/ufw/ufw.conf"))
	f.copy("hand/nftables.conf", "fs/etc/nftables.conf")
	fs, _ = f.check()
	if x := fs["security.exposed.tcp-8765"]; x.State != "fail" || !strings.Contains(x.Detail, "could not be determined") {
		t.Errorf("nft: %+v", x)
	}
	// allow_ports accepts it
	f.write("root/hostcare.conf", "allow_ports=tcp/8765\n")
	fs, as = f.check()
	if _, ok := fs["security.exposed.tcp-8765"]; ok || as["exposed"].State != "ok" {
		t.Errorf("allowed: %+v", fs["security.exposed.tcp-8765"])
	}
}

func TestSet(t *testing.T) {
	f := newFake(t)
	set := func(in string) error {
		_, err := f.verb(func(o *out.Writer) error { return f.h.Set(o, strings.NewReader(in)) })
		return err
	}
	if err := set("updates_days=5\nssh=off\nallow_ports=tcp/5432,udp/51820\n"); err != nil {
		t.Fatal(err)
	}
	s := LoadSettings(f.h.confPath())
	if s.Num("updates_days") != 5 || s.On("ssh") || !s.AllowedPorts()["udp/51820"] {
		t.Errorf("%v", s)
	}
	for _, bad := range []string{"care_reboot=on\n", "nope=1\n", "ssh=maybe\n", "updates_days=x\n", "allow_ports=5432\n", "boot_pct=20\n", "allow_ports=tcp/99999\n", "x\n", "eol=on\x1b\n"} {
		if err := set(bad); err == nil {
			t.Errorf("accepted %q", bad)
		}
	}
	if err := set("updates_days=\n"); err != nil || LoadSettings(f.h.confPath()).Num("updates_days") != 3 {
		t.Error("key= resets")
	}
	if fi, _ := os.Stat(f.h.confPath()); fi.Mode().Perm() != 0o644 {
		t.Errorf("mode %v", fi.Mode())
	}
	f.h.Env.EUID = 1000
	if err := set("ssh=on\n"); err == nil {
		t.Error("set without root")
	}
}

func TestCareOnOff(t *testing.T) {
	f := newFake(t)
	on := func(args ...string) (string, error) {
		return f.verb(func(o *out.Writer) error { return f.h.CareOn(ctx, o, args) })
	}
	o, err := on("updates")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(f.p("fs" + aptCareFile))
	if !strings.Contains(string(b), "-security") || strings.Contains(string(b), "-updates\"") || !strings.Contains(o, "changed=") || !strings.Contains(o, "care_updates=on") {
		t.Errorf("care on: %s / %s", o, b)
	}
	if b, _ := os.ReadFile(f.p("fs" + uuDropinFile)); !strings.Contains(string(b), "NEEDRESTART_SUSPEND=1") {
		t.Error("needrestart guard")
	}
	if f.called("apt-get install") {
		t.Error("installed unattended-upgrades although it is there")
	}
	for _, u := range []string{"tando-host.service", "tando-host.timer", "tando-host-boot.service"} {
		if _, err := os.Stat(f.h.unitPath(u)); err != nil {
			t.Errorf("unit %s: %v", u, err)
		}
	}
	// a second run changes nothing
	f.reset()
	o, _ = on("updates")
	if !strings.Contains(o, "changed=\n") || f.called("systemctl daemon-reload") {
		t.Errorf("second run: %s %v", o, f.calls)
	}
	// reboot: needs a confirmation, then the window's units
	if _, err := on("reboot"); err == nil || !strings.Contains(err.Error(), "confirmation") {
		t.Errorf("reboot without confirmation: %v", err)
	}
	if o, err = on("reboot", "confirmed", "window=03:00-05:00", "tz=Asia/Jakarta"); err != nil {
		t.Fatal(err)
	}
	b, _ = os.ReadFile(f.h.unitPath("tando-host-window.timer"))
	if !strings.Contains(string(b), "OnCalendar=*-*-* 03:00:00 Asia/Jakarta") || !strings.Contains(o, "care_reboot=on") {
		t.Errorf("window: %s / %s", b, o)
	}
	for _, bad := range [][]string{{"window=3-5"}, {"tz=Mars/Base"}, {"tz=../etc"}, {"lead=999"}, {"bogus"}} {
		if _, err := on(bad...); err == nil {
			t.Errorf("accepted %v", bad)
		}
	}
	// off: care's files go, unattended-upgrades stays
	o, err = f.verb(func(o *out.Writer) error { return f.h.CareOff(ctx, o, nil) })
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(f.p("fs" + aptCareFile)); err == nil {
		t.Error("care file kept")
	}
	if _, err := os.Stat(f.h.unitPath("tando-host-window.timer")); err == nil {
		t.Error("window kept")
	}
	if !strings.Contains(o, "care_updates=off") || !strings.Contains(o, "care_reboot=off") {
		t.Errorf("off: %s", o)
	}
	f.reset()
	o, _ = f.verb(func(o *out.Writer) error { return f.h.CareOff(ctx, o, nil) })
	if !strings.Contains(o, "changed=\n") {
		t.Errorf("second off: %s", o)
	}
}

func TestCareOtherSites(t *testing.T) {
	f := newFake(t)
	f.write("root/host.conf", "apps_domain=localhost\n")
	f.write("fs/etc/caddy/Caddyfile", "example.com {\n\treverse_proxy :3000\n}\nimport /etc/caddy/tando/*.caddy\n")
	_, err := f.verb(func(o *out.Writer) error { return f.h.CareOn(ctx, o, []string{"reboot", "confirmed"}) })
	if err == nil || !strings.Contains(err.Error(), "does not manage") {
		t.Errorf("other sites: %v", err)
	}
	// host setup's install on such a server turns nothing on
	o, err := f.verb(func(o *out.Writer) error { return f.h.Install(ctx, o, nil) })
	if err != nil || !strings.Contains(o, "care_updates=off") || !strings.Contains(o, "caddy_ours=0") {
		t.Errorf("install with other sites: %s %v", o, err)
	}
	if _, err := os.Stat(f.p("fs" + aptCareFile)); err == nil {
		t.Error("care turned on beside other sites")
	}
	// a fresh server (Caddy installed by tando): security updates on by default, care=off respected
	g := newFake(t)
	o, _ = g.verb(func(o *out.Writer) error { return g.h.Install(ctx, o, nil) })
	if !strings.Contains(o, "care_updates=on") {
		t.Errorf("fresh: %s", o)
	}
	h := newFake(t)
	o, _ = h.verb(func(o *out.Writer) error { return h.h.Install(ctx, o, []string{"care=off"}) })
	if !strings.Contains(o, "care_updates=off") {
		t.Errorf("care=off: %s", o)
	}
	o, _ = h.verb(func(o *out.Writer) error { return h.h.Install(ctx, o, nil) }) // decided before: unchanged
	if !strings.Contains(o, "care_updates=off") {
		t.Errorf("rerun: %s", o)
	}
}

func TestUpdate(t *testing.T) {
	f := newFake(t)
	f.answer["apt-get -s"] = string(fixture(t, "ubuntu24/apt-sim-dist-upgrade.txt")) +
		"Inst curl [8.5.0-2ubuntu10.5] (8.5.0-2ubuntu10.6 Ubuntu:24.04/noble-updates [arm64])\n"
	o, err := f.verb(func(o *out.Writer) error { return f.h.UpdatePlan(ctx, o, nil) })
	if err != nil || !strings.Contains(o, "pkg\tlibc6\t") || !strings.Contains(o, "security=2") || !strings.Contains(o, "other=1") || !f.called("apt-get update -q") {
		t.Errorf("plan: %s %v", o, err)
	}
	f.reset()
	o, err = f.verb(func(o *out.Writer) error { return f.h.UpdateApply(ctx, o, nil) })
	if err != nil {
		t.Fatal(err)
	}
	want := "apt-get install -y -q --only-upgrade --no-remove -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold libc6 libc-bin"
	if !f.called(want) || f.called("apt-get install -y -q --only-upgrade --no-remove -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold libc6 libc-bin curl") {
		t.Errorf("apply: %v", f.calls)
	}
	for i, c := range f.calls {
		if strings.HasPrefix(c, "apt-get install") && !strings.Contains(strings.Join(f.envs[i], " "), "NEEDRESTART_SUSPEND=1") {
			t.Error("install without the needrestart guard")
		}
	}
	if !strings.Contains(o, "upgraded=2") || !f.called("/opt/tando/bin/tando-logs audit-write host-update - 0 tando-host: 2 packages") {
		t.Errorf("apply out: %s %v", o, f.calls)
	}
	f.reset()
	f.verb(func(o *out.Writer) error { return f.h.UpdateApply(ctx, o, []string{"all"}) })
	if !f.called("apt-get upgrade -y -q --with-new-pkgs") {
		t.Error("--all")
	}
	// a cut-off dpkg is finished first
	f.answer["dpkg --audit"] = string(fixture(t, "hand/dpkg-audit.txt"))
	f.check()
	f.reset()
	f.verb(func(o *out.Writer) error { return f.h.UpdateApply(ctx, o, nil) })
	if !f.called("dpkg --configure -a") {
		t.Error("dpkg --configure -a")
	}
	fs, as := f.summary()
	if fs["updates.dpkg"].State != "" && as["updates"].State == "" {
		t.Error("summary")
	}
	// apt failing is said, with where to look
	f.fail["apt-get install"] = true
	if _, err := f.verb(func(o *out.Writer) error { return f.h.UpdateApply(ctx, o, nil) }); err == nil || !strings.Contains(err.Error(), "tando-apt.log") {
		t.Errorf("failed apply: %v", err)
	}
}

func TestRebootManual(t *testing.T) {
	f := newFake(t)
	f.write("fs/run/reboot-required.pkgs", "linux-image-6.8.0-52-generic\n")
	f.app("shop", "port=4100\nbackup=daily\nhealth=/health\n", "current=20261117-010101\nphase=idle\nlast_backup=1\n")
	// outside the window, without now: planned for the window
	f.now = time.Date(2026, 11, 17, 12, 0, 0, 0, time.UTC)
	o, err := f.verb(func(o *out.Writer) error { return f.h.Reboot(ctx, o, nil) })
	if err != nil || !strings.Contains(o, "planned=1") || f.called("systemctl --no-block reboot") {
		t.Fatalf("plan: %s %v", o, err)
	}
	if _, err := os.Stat(f.h.unitPath("tando-host-window.timer")); err != nil {
		t.Error("a planned reboot needs the window's timer")
	}
	// a deploy in progress: refused, saying why
	f.write("root/apps/shop/state", "current=20261117-010101\nphase=verify\nlast_backup=1\n")
	_, err = f.verb(func(o *out.Writer) error { return f.h.Reboot(ctx, o, []string{"now"}) })
	if err == nil || !strings.Contains(err.Error(), "deploy of shop") || f.called("systemctl --no-block reboot") {
		t.Errorf("busy: %v", err)
	}
	// now: the stale backup first, the notice, the marker, the reboot
	f.write("root/apps/shop/state", "current=20261117-010101\nphase=idle\nlast_backup=1\n")
	o, err = f.verb(func(o *out.Writer) error { return f.h.Reboot(ctx, o, []string{"now"}) })
	if err != nil || !strings.Contains(o, "rebooting=1") || !strings.Contains(o, "boot_id=boot-1") {
		t.Fatalf("now: %s %v", o, err)
	}
	order := []string{"/opt/tando/bin/tando-agent backup-run shop manual", "/opt/tando/bin/tando-logs audit-write host-reboot", "systemctl start tando-watch.service", "systemctl --no-block reboot"}
	i := 0
	for _, c := range f.calls {
		if i < len(order) && strings.HasPrefix(c, order[i]) {
			i++
		}
	}
	if i != len(order) {
		t.Errorf("order: %v", f.calls)
	}
	ents, _ := os.ReadDir(f.p("lib/watch/inbox"))
	if len(ents) != 1 {
		t.Fatalf("inbox: %v", ents)
	}
	b, _ := os.ReadFile(filepath.Join(f.p("lib/watch/inbox"), ents[0].Name()))
	if !strings.HasPrefix(string(b), "monitor\thost\t-\trebooting now for a new kernel") {
		t.Errorf("notice: %q", b)
	}
	// after the boot: every app answers -> done, ok, proven
	f.write("proc/sys/kernel/random/boot_id", "boot-2\n")
	f.healthy["shop"] = true
	f.advance(40 * time.Second)
	o, err = f.verb(func(o *out.Writer) error { return f.h.AfterBoot(ctx, o) })
	if err != nil || !strings.Contains(o, "result=ok") || !strings.Contains(o, "secs=40") {
		t.Errorf("after boot: %s %v", o, err)
	}
	if loadState(f.h.statePath()).num("reboot.ok") == 0 {
		t.Error("not proven after a healthy reboot")
	}
	o, _ = f.verb(func(o *out.Writer) error { return f.h.RebootResult(o) })
	if !strings.Contains(o, "state=done") || !strings.Contains(o, "boot_now=boot-2") {
		t.Errorf("result: %s", o)
	}
	// once more after the same boot: nothing
	o, _ = f.verb(func(o *out.Writer) error { return f.h.AfterBoot(ctx, o) })
	if !strings.Contains(o, "reboot=none") {
		t.Errorf("second after-boot: %s", o)
	}
	// an app that does not come back: failed, named, high priority notice
	f.write(f.h.rebootPath()[len(f.dir)+1:], "state=rebooting\nat="+i64(f.now.Unix())+"\nboot_id=boot-2\nwhy=x\n")
	f.write("proc/sys/kernel/random/boot_id", "boot-3\n")
	f.healthy["shop"] = false
	o, _ = f.verb(func(o *out.Writer) error { return f.h.AfterBoot(ctx, o) })
	if !strings.Contains(o, "result=failed") || !strings.Contains(o, "failed=shop") {
		t.Errorf("unhealthy: %s", o)
	}
}

func TestMaintain(t *testing.T) {
	f := newFake(t)
	f.write("fs/run/reboot-required", "x")
	f.write("root/hostcare.conf", "care_reboot=on\nreboot_ok=1\nwindow=02:00-04:00\nlead_min=10\n")
	f.now = time.Date(2026, 11, 18, 2, 0, 5, 0, time.UTC)
	o, err := f.verb(func(o *out.Writer) error { return f.h.Maintain(ctx, o) })
	if err != nil || !strings.Contains(o, "rebooting=1") || !f.called("systemctl --no-block reboot") {
		t.Fatalf("maintain: %s %v %v", o, err, f.calls)
	}
	if got := f.now.Sub(time.Date(2026, 11, 18, 2, 0, 5, 0, time.UTC)); got < 10*time.Minute {
		t.Errorf("rebooted after %v, not after the lead time", got)
	}
	// skip during the countdown cancels it
	g := newFake(t)
	g.write("fs/run/reboot-required", "x")
	g.write("root/hostcare.conf", "care_reboot=on\nreboot_ok=1\n")
	g.now = time.Date(2026, 11, 18, 2, 0, 5, 0, time.UTC)
	n := 0
	g.h.Sleep = func(d time.Duration) {
		g.advance(d)
		if n++; n == 3 {
			g.verb(func(o *out.Writer) error { return g.h.CareSkip(ctx, o, nil) })
		}
	}
	o, _ = g.verb(func(o *out.Writer) error { return g.h.Maintain(ctx, o) })
	if !strings.Contains(o, "reboot=skipped") || g.called("systemctl --no-block reboot") || g.h.skipped() {
		t.Errorf("skip: %s", o)
	}
	// a deploy during the whole window: no reboot, and it says why
	h := newFake(t)
	h.write("fs/run/reboot-required", "x")
	h.write("root/hostcare.conf", "care_reboot=on\nreboot_ok=1\nlead_min=0\n")
	h.app("shop", "port=4100\n", "current=1\nphase=switch\n")
	h.now = time.Date(2026, 11, 18, 2, 0, 5, 0, time.UTC)
	o, _ = h.verb(func(o *out.Writer) error { return h.h.Maintain(ctx, o) })
	if !strings.Contains(o, "reboot=no") || h.called("systemctl --no-block reboot") || !strings.Contains(o, "deploy of shop") {
		t.Errorf("busy window: %s", o)
	}
	// other sites: never, and the reason says so
	k := newFake(t)
	k.write("fs/run/reboot-required", "x")
	k.write("root/host.conf", "apps_domain=localhost\n")
	k.write("fs/etc/caddy/Caddyfile", "example.com {\n}\n")
	k.write("root/hostcare.conf", "care_reboot=on\nreboot_ok=1\n")
	k.now = time.Date(2026, 11, 18, 2, 0, 5, 0, time.UTC)
	o, _ = k.verb(func(o *out.Writer) error { return k.h.Maintain(ctx, o) })
	if !strings.Contains(o, "does not manage") || k.called("systemctl --no-block reboot") {
		t.Errorf("other sites: %s", o)
	}
}

func TestStatusAndDoctorRows(t *testing.T) {
	f := newFake(t)
	f.answer["/opt/tando/bin/tando-watch doctor"] = "check\tok\ttandod\trunning since 2h\ncheck\twarn\tnotifiers\tnone yet\n"
	o, err := f.verb(func(o *out.Writer) error { return f.h.Status(ctx, o) })
	if err != nil {
		t.Fatal(err)
	}
	for _, w := range []string{"sys\tvps1\tUbuntu 24.04", "care\toff\toff\t02:00-04:00\tUTC", "finding\tsecurity\tsecurity.exposed.tcp-8765\tfail", "check\twarn\tnotifiers\tnone yet"} {
		if !strings.Contains(o, w) {
			t.Errorf("status lacks %q:\n%s", w, o)
		}
	}
	o, _ = f.verb(func(o *out.Writer) error { return f.h.Doctor(o) })
	if !strings.Contains(o, "check\twarn\thost care\t") || !strings.Contains(o, "failing: tando host status <host>") {
		t.Errorf("doctor: %s", o)
	}
	f.advance(4 * time.Hour)
	o, _ = f.verb(func(o *out.Writer) error { return f.h.Doctor(o) })
	if !strings.Contains(o, "tando-host.timer") {
		t.Errorf("stale: %s", o)
	}
}

// hostile text from the host (a process name, a unit name, a journal line, a package name)
// never reaches the output, the summary or a notice as it is
func TestOutputClean(t *testing.T) {
	f := newFake(t)
	f.proc(200, outtest.Hostile, "0::/system.slice/evil\x1b.service\n", 21150262)
	f.answer["systemctl show -p SystemState"] = "SystemState=deg\x1b[31mraded\nNFailedUnits=1\n"
	f.answer["systemctl list-units"] = "ev\x1bil.service loaded failed failed x\nok.service loaded failed failed " + outtest.Hostile + "\n"
	f.answer["journalctl"] = `{"__REALTIME_TIMESTAMP":"1763366400000000","_TRANSPORT":"kernel","MESSAGE":"I/O error ` + strings.ReplaceAll(outtest.Hostile, "\x1b", `\u001b`) + `"}` + "\n"
	f.answer["apt-get -s"] = "Inst lib\x1bc6 [1] (2 Ubuntu:24.04/noble-security [arm64])\nInst ok-pkg [1] (2" + "\u202e" + " Ubuntu:24.04/noble-security [arm64])\n"
	f.write("fs/etc/os-release", "ID=ubuntu\nVERSION_ID=24.04\nPRETTY_NAME=\""+outtest.Hostile+"\"\n")
	f.answer["/opt/tando/bin/tando-watch doctor"] = "check\tok\t" + outtest.Hostile + "\tx\n"
	o, err := f.verb(func(o *out.Writer) error { return f.h.Status(ctx, o) })
	if err != nil {
		t.Fatal(err)
	}
	if err := outtest.Check([]byte(o)); err != nil {
		t.Errorf("status: %v", err)
	}
	b, _ := os.ReadFile(f.h.SummaryPath())
	if err := outtest.Check(b); err != nil {
		t.Errorf("summary: %v", err)
	}
	f.h.notice(ctx, "x "+outtest.Hostile+"\ny", false)
	ents, _ := os.ReadDir(f.p("lib/watch/inbox"))
	for _, e := range ents {
		b, _ := os.ReadFile(filepath.Join(f.p("lib/watch/inbox"), e.Name()))
		if err := outtest.Check(b); err != nil || strings.Count(string(b), "\n") != 1 {
			t.Errorf("notice: %v %q", err, b)
		}
	}
}

// in a container the kernel's boot id stays the same across a "reboot": PID 1's start tells
func TestBootID(t *testing.T) {
	f := newFake(t)
	f.write("proc/1/stat", "1 (systemd) S 0 1 1 0 -1 4194560 1 2 3 4 5 6 7 8 20 0 1 0 4242 0 0\n")
	if id := bootID(f.h.Env.Proc); id != "boot-1-4242" {
		t.Errorf("%q", id)
	}
}

// in a container the load, memory and clock are the host's: "unknown", never counted or alerted
func TestContainerUnknown(t *testing.T) {
	f := newFake(t)
	f.answer["systemctl show -p SystemState"] = "SystemState=running\nNFailedUnits=0\nVirtualization=docker\n"
	f.write("proc/loadavg", "50.0 50.0 50.0 1/100 1\n")
	f.synced = false
	fs, as := f.check()
	for _, id := range []string{"health.load", "health.memory", "health.clock"} {
		if fs[id].State != "unknown" || fs[id].Fix != "-" {
			t.Errorf("%s: %+v", id, fs[id])
		}
	}
	if as["clock"].State != "ok" {
		t.Errorf("clock alert: %+v", as["clock"])
	}
	all := []Finding{}
	for _, x := range fs {
		all = append(all, x)
	}
	todo, _, _ := Counts(all)
	n := 0
	for _, x := range fs {
		if x.State == "warn" || x.State == "fail" {
			n++
		}
	}
	if todo != n {
		t.Errorf("unknown counted: %d vs %d", todo, n)
	}
}
