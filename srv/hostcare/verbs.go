package hostcare

import (
	"context"
	"errors"
	"os"
	"strconv"
	"strings"
	"time"

	"tando/srv/internal/bashread"
	"tando/srv/internal/out"
	"tando/srv/internal/run"
)

// run is one pass: collect, judge, and (write) save the state and the summary. apt: run the
// slow pass now.
func (h *Host) run(ctx context.Context, apt, write bool) (Facts, []Finding, []Alert, *State, error) {
	s := LoadSettings(h.confPath())
	st := loadState(h.statePath())
	f := h.Collect(ctx, st, s, apt)
	fs, as := Judge(f, s, st)
	if write {
		if err := h.writeSummary(f, fs, as); err != nil {
			return f, fs, as, st, err
		}
		if err := st.save(h.statePath()); err != nil {
			return f, fs, as, st, err
		}
	}
	return f, fs, as, st, nil
}

// Check is the verb `check [apt]` (tando-host.timer, hourly): the facts, the summary file,
// the audit lines of upgrades unattended-upgrades made, and care's housekeeping.
func (h *Host) Check(ctx context.Context, o *out.Writer, args []string) error {
	if err := h.needRoot(); err != nil {
		return err
	}
	l, err := h.lock()
	if err != nil {
		return err
	}
	defer l.Release()
	f, fs, _, st, err := h.run(ctx, len(args) > 0 && args[0] == "apt", true)
	if err != nil {
		return err
	}
	h.auditUpgrades(ctx, f, st)
	h.housekeeping(ctx, f)
	st.save(h.statePath())
	todo, fail, warn := Counts(fs)
	o.KV("todo", strconv.Itoa(todo))
	o.KV("fail", strconv.Itoa(fail))
	o.KV("warn", strconv.Itoa(warn))
	o.KV("at", i64(f.At))
	o.KV("apt_at", i64(f.Apt.At))
	return nil
}

// auditUpgrades writes one audit line for each apt run of unattended-upgrades that changed
// packages since the last check (the first check only remembers where the history is).
func (h *Host) auditUpgrades(ctx context.Context, f Facts, st *State) {
	seen := st.num("hist.seen")
	newest := seen
	for _, u := range f.Apt.History {
		if u.At > newest {
			newest = u.At
		}
		if seen == 0 || u.At <= seen || u.By != "unattended-upgrade" {
			continue
		}
		h.audit(ctx, "host-upgraded", true, "unattended-upgrades installed "+plural(len(u.Pkgs), "package")+": "+list(u.Pkgs, 8))
	}
	if newest > 0 {
		st.setNum("hist.seen", newest)
	}
}

// housekeeping (care mode only): care's files back when they went missing, and old kernels
// removed when /boot fills up (apt-get autoremove; the journal is capped by tando-logs).
func (h *Host) housekeeping(ctx context.Context, f Facts) {
	s := LoadSettings(h.confPath())
	if s["care_updates"] != "on" {
		return
	}
	if d, err := h.applyCareUpdates(ctx); err == nil && d != "" {
		h.audit(ctx, "host-care", true, "repaired: "+d)
	}
	for _, d := range f.Disks {
		if d.Mount == "/boot" && int64(d.Pct) >= s.Num("boot_pct")-10 {
			if h.autoremove(ctx) {
				h.audit(ctx, "host-care", true, "/boot was "+strconv.Itoa(d.Pct)+"% full: removed old kernels (apt-get autoremove)")
			}
		}
	}
}

func (h *Host) autoremove(ctx context.Context) bool {
	if dpkgLockHolder(h.p("/var/lib/dpkg/lock-frontend")) != 0 {
		return false
	}
	lf := h.logFile()
	if lf != nil {
		defer lf.Close()
	}
	_, err := h.Env.Run.Output(ctx, run.Cmd{Argv: []string{"apt-get", "autoremove", "-y", "-q", "--purge"}, Env: aptEnv, Stdout: lf, Stderr: lf, Timeout: 20 * time.Minute})
	h.Env.Run.Output(ctx, run.Cmd{Argv: []string{"apt-get", "clean"}, Env: aptEnv, Timeout: 5 * time.Minute})
	return err == nil
}

// Status is the verb `status`: rows for `tando host status` (lib/cmd-host.sh):
//
//	sys      hostname os kernel arch virt uptime cpus load5 mem_total mem_used disk_total disk_used swap_total swap_used at apt_at caddy_ours
//	care     updates reboot window zone lead other_sites proven skip next_window
//	finding  section id state since auto rank title detail fix
//	upgraded at by count packages
//	check    state name detail          (tando itself: tando-watch doctor's rows)
//
// It collects like a check and writes the summary when no other run holds the lock.
func (h *Host) Status(ctx context.Context, o *out.Writer) error {
	if err := h.needRoot(); err != nil {
		return err
	}
	write := false
	if err := h.mkdir(); err == nil {
		if l, err := h.lock(); err == nil {
			defer l.Release()
			write = true
		}
	}
	f, fs, _, _, err := h.run(ctx, false, write)
	if err != nil {
		return err
	}
	s := LoadSettings(h.confPath())
	var disk Disk
	for _, d := range f.Disks {
		if d.Mount == "/" {
			disk = d
		}
	}
	o.Row("sys", f.Hostname, f.OSName, f.Kernel, f.Arch, f.Virt, i64(f.Uptime), strconv.Itoa(f.CPUs), f.Load5,
		i64(f.MemTotal*1024), i64((f.MemTotal-f.MemAvail)*1024), i64(disk.TotalKB*1024), i64(disk.UsedKB*1024),
		i64(f.SwapTotal*1024), i64((f.SwapTotal-f.SwapFree)*1024), i64(f.At), i64(f.Apt.At), b01(f.CaddyOurs))
	st := loadState(h.statePath())
	next := ""
	if loc, err := s.Location(h.Loc); err == nil {
		if ws, _, ok := ParseWindow(s["window"]); ok {
			next = i64(NextWindow(h.Env.Now(), loc, ws).Unix())
		}
		o.Row("care", s["care_updates"], s["care_reboot"], s["window"], loc.String(), s["lead_min"], s["other_sites"],
			b01(st.num("reboot.ok") > 0 || num(s["reboot_ok"]) > 0), b01(h.skipped()), next)
	}
	for _, x := range fs {
		o.Row("finding", x.Section, x.ID, x.State, i64(x.Since), b01(x.Auto), strconv.Itoa(x.Rank), x.Title, x.Detail, x.Fix)
	}
	for i := len(f.Apt.History) - 1; i >= 0 && i >= len(f.Apt.History)-3; i-- {
		u := f.Apt.History[i]
		o.Row("upgraded", i64(u.At), u.By, strconv.Itoa(len(u.Pkgs)), list(u.Pkgs, 6))
	}
	// tando itself: tando-watch's own rows of tando doctor (the checks running, notifiers)
	if b, err := h.Env.Run.Output(ctx, run.Cmd{Argv: []string{"/opt/tando/bin/tando-watch", "doctor"}, Timeout: 20 * time.Second}); err == nil {
		for _, l := range bashread.Lines(b) {
			p := bashread.Fields(l, 4)
			if p[0] == "check" {
				o.Row("check", p[1], p[2], p[3])
			}
		}
	}
	return nil
}

// Doctor is the verb `doctor`: tando doctor's row for host care, from the last summary (cheap:
// no facts are collected).
func (h *Host) Doctor(o *out.Writer) error {
	todo, fail, _, at, ok := Brief(h.SummaryPath())
	if !ok {
		o.Row("check", "ok", "host care", "first check within the hour")
		return nil
	}
	age := h.now() - num(at)
	switch {
	case age > 3*3600:
		o.Row("check", "warn", "host care", "the hourly check last ran "+ago(h.now(), num(at))+": sudo systemctl status tando-host.timer (on the server)")
	case todo == "0":
		o.Row("check", "ok", "host care", "nothing to do (tando host status <host>)")
	case fail != "0": // (warn, not fail: doctor's fail is for tando itself being broken)
		o.Row("check", "warn", "host care", todo+" to do, "+fail+" failing: tando host status <host>")
	default:
		o.Row("check", "ok", "host care", todo+" to do: tando host status <host>")
	}
	return nil
}

// ---- updates ----------------------------------------------------------------------------------

// UpdatePlan is the verb `update-plan [all]`: refresh the package lists, then what an update
// would install: "pkg name old new security(0|1)" rows and counts.
func (h *Host) UpdatePlan(ctx context.Context, o *out.Writer, args []string) error {
	if err := h.needRoot(); err != nil {
		return err
	}
	l, err := h.lock()
	if err != nil {
		return err
	}
	defer l.Release()
	lf := h.logFile()
	if lf != nil {
		defer lf.Close()
	}
	if _, err := h.Env.Run.Output(ctx, run.Cmd{Argv: []string{"apt-get", "update", "-q"}, Env: aptEnv, Stdout: lf, Stderr: lf, Timeout: 10 * time.Minute}); err != nil {
		o.KV("lists", "failed")
	} else {
		o.KV("lists", "refreshed")
	}
	a := h.aptFacts(ctx, LoadSettings(h.confPath()), true)
	sec := 0
	for _, p := range a.Pkgs {
		if p.Security {
			sec++
		}
		o.Row("pkg", p.Name, p.Old, p.New, b01(p.Security))
	}
	o.KV("security", strconv.Itoa(sec))
	o.KV("other", strconv.Itoa(len(a.Pkgs)-sec))
	o.KV("held", strings.Join(a.Held, ","))
	o.KV("dpkg_broken", b01(len(a.Broken)+len(a.Audit) > 0))
	if a.Err != "" {
		o.KV("error", a.Err)
	}
	return nil
}

// UpdateApply is the verb `update-apply [all]`: finish a cut-off dpkg run, install the pending
// security updates (all: every update apt would install without removing a package), remove old
// kernels when /boot fills up; apt's own output goes to /var/log/tando-apt.log. No service tando
// does not manage is restarted (NEEDRESTART_SUSPEND); what needs a reboot is said.
func (h *Host) UpdateApply(ctx context.Context, o *out.Writer, args []string) error {
	if err := h.needRoot(); err != nil {
		return err
	}
	all := len(args) > 0 && args[0] == "all"
	l, err := h.lock()
	if err != nil {
		return err
	}
	defer l.Release()
	if pid := dpkgLockHolder(h.p("/var/lib/dpkg/lock-frontend")); pid != 0 {
		return errors.New("apt is busy (another install, probably unattended-upgrades): try again in a few minutes")
	}
	lf := h.logFile()
	if lf != nil {
		defer lf.Close()
	}
	s := LoadSettings(h.confPath())
	before := h.aptFacts(ctx, s, false)
	if len(before.Broken)+len(before.Audit) > 0 {
		h.Env.Run.Output(ctx, run.Cmd{Argv: []string{"dpkg", "--configure", "-a"}, Env: aptEnv, Stdout: lf, Stderr: lf, Timeout: 30 * time.Minute})
		o.KV("dpkg", "configured")
	}
	b, err := h.Env.Run.Output(ctx, run.Cmd{Argv: []string{"apt-get", "-s", "-o", "Debug::NoLocking=1", "dist-upgrade"}, Timeout: 3 * time.Minute})
	if err != nil {
		return errors.New("apt-get could not plan the update: sudo apt-get -s dist-upgrade (on the server) says why")
	}
	var names []string
	for _, p := range ParseAptSim(b) {
		if (all || p.Security) && pkgName(p.Name) && p.Old != "" {
			names = append(names, p.Name)
		}
	}
	var applyErr error
	switch {
	case all:
		_, applyErr = h.Env.Run.Output(ctx, run.Cmd{Argv: []string{"apt-get", "upgrade", "-y", "-q", "--with-new-pkgs",
			"-o", "Dpkg::Options::=--force-confdef", "-o", "Dpkg::Options::=--force-confold"}, Env: aptEnv, Stdout: lf, Stderr: lf, Timeout: time.Hour})
	case len(names) > 0:
		_, applyErr = h.Env.Run.Output(ctx, run.Cmd{Argv: append([]string{"apt-get", "install", "-y", "-q", "--only-upgrade", "--no-remove",
			"-o", "Dpkg::Options::=--force-confdef", "-o", "Dpkg::Options::=--force-confold"}, names...), Env: aptEnv, Stdout: lf, Stderr: lf, Timeout: time.Hour})
	}
	for _, d := range h.bootDisks() {
		if d.Pct >= 70 && h.autoremove(ctx) {
			o.KV("autoremove", "old kernels removed (/boot was "+strconv.Itoa(d.Pct)+"% full)")
		}
	}
	after := h.aptFacts(ctx, s, true)
	left := len(after.Security())
	what := "security updates"
	if all {
		what, left = "updates", len(after.Pkgs)
	}
	note := plural(len(names), "package") + " (" + what + "): " + list(names, 8)
	if applyErr != nil {
		h.audit(ctx, "host-update", false, "failed: "+note)
		return errors.New("apt could not install the " + what + ": sudo tail -30 " + aptLog + " (on the server) says why")
	}
	if len(names) > 0 || all {
		h.audit(ctx, "host-update", true, note)
	}
	o.KV("upgraded", strconv.Itoa(len(names)))
	o.KV("packages", list(names, 12))
	o.KV("left", strconv.Itoa(left))
	o.KV("reboot", b01(mtime(h.p("/run/reboot-required")) > 0))
	o.KV("restart", list(after.NR.Services, 4))
	h.run(ctx, false, true) // the summary now, not in an hour
	return nil
}

func (h *Host) bootDisks() []Disk {
	var f Facts
	h.disks(&f)
	var res []Disk
	for _, d := range f.Disks {
		if d.Mount == "/boot" {
			res = append(res, d)
		}
	}
	return res
}

// ---- reboots ----------------------------------------------------------------------------------

// rebootWhy: what the reboot is for, from /run/reboot-required.pkgs.
func (h *Host) rebootWhy() string {
	pk := lines(readFile(h.p("/run/reboot-required.pkgs"), 64<<10), 200)
	for _, p := range pk {
		if strings.HasPrefix(p, "linux-") {
			return "a new kernel"
		}
	}
	var ok []string
	for _, p := range pk {
		if pkgName(p) {
			ok = append(ok, p)
		}
	}
	if len(ok) > 0 {
		return "security updates (" + list(ok, 3) + ")"
	}
	return ""
}

// RebootPlan is the verb `reboot-plan [now] [other-sites]`: what `reboot` would do now, as
// key=value lines (nothing changes).
func (h *Host) RebootPlan(o *out.Writer, args []string) error {
	if err := h.needRoot(); err != nil {
		return err
	}
	s := LoadSettings(h.confPath())
	in, err := h.rebootInput(s, loadState(h.statePath()), true, hasWord(args, "now"))
	if err != nil {
		return err
	}
	in.OtherSitesOK = in.OtherSitesOK || hasWord(args, "other-sites")
	d := DecideReboot(in)
	h.printDecision(o, d, in)
	return nil
}

func (h *Host) printDecision(o *out.Writer, d RebootDecision, in RebootInput) {
	o.KV("go", b01(d.Go))
	o.KV("wait", b01(d.Wait))
	if d.Wait {
		o.KV("at", i64(d.At.Unix()))
	}
	o.KV("reason", d.Reason)
	o.KV("backup_first", strings.Join(d.BackupFirst, ","))
	o.KV("caddy_ours", b01(in.CaddyOurs))
	o.KV("required", b01(in.Required))
	o.KV("why", h.rebootWhy())
	o.KV("zone", in.Loc.String())
	o.KV("window", minutes(in.WindowStart)+"-"+minutes(in.WindowEnd))
	o.KV("boot_id", bootID(h.Env.Proc))
}

func minutes(m int) string {
	return strconv.Itoa(m/60/10) + strconv.Itoa(m/60%10) + ":" + strconv.Itoa(m%60/10) + strconv.Itoa(m%10)
}

func hasWord(args []string, w string) bool {
	for _, a := range args {
		if a == w {
			return true
		}
	}
	return false
}

// Reboot is the verb `reboot [now] [other-sites]` (tando host reboot): the same rules as care's
// reboots, asked by the owner. Without now and outside the window it is planned for the window
// (planned=1, at=<epoch>); with now (or inside the window) it reboots: backups first when stale,
// a notice, the marker for after-boot, `systemctl reboot` (rebooting=1, boot_id=<before>).
func (h *Host) Reboot(ctx context.Context, o *out.Writer, args []string) error {
	if err := h.needRoot(); err != nil {
		return err
	}
	l, err := h.lock()
	if err != nil {
		return err
	}
	s := LoadSettings(h.confPath())
	st := loadState(h.statePath())
	in, err := h.rebootInput(s, st, true, hasWord(args, "now"))
	if err != nil {
		l.Release()
		return err
	}
	in.OtherSitesOK = in.OtherSitesOK || hasWord(args, "other-sites")
	d := DecideReboot(in)
	switch {
	case d.Wait:
		st.setNum("planned", h.now())
		err := st.save(h.statePath())
		if err == nil {
			_, err = h.installUnits(ctx, s, st)
		}
		l.Release()
		if err != nil {
			return err
		}
		h.audit(ctx, "host-reboot", true, "planned for the window "+s["window"])
		o.KV("planned", "1")
		o.KV("at", i64(d.At.Unix()))
		o.KV("zone", in.Loc.String())
		return nil
	case !d.Go:
		l.Release()
		return errors.New(d.Reason)
	}
	l.Release()
	who := "the owner"
	if h.SudoUser != "" {
		who = clean(h.SudoUser, 32)
	}
	why := h.rebootWhy()
	if why == "" {
		why = "asked by " + who
	}
	// the answer leaves before the reboot does (ssh goes down with it)
	_, err = h.doReboot(ctx, d.BackupFirst, "manual", who, why, nil, func(id string) {
		o.KV("rebooting", "1")
		o.KV("boot_id", id)
		o.Flush()
	})
	return err
}

// doReboot: backups first, the marker, the audit line, the notice (sent before the reboot),
// then `systemctl reboot`. It returns the boot id before the reboot.
// recheck (may be nil) is asked once more after the backups, which can take long: a reason not to
// reboot any more (a deploy started, the window closed) stops it.
func (h *Host) doReboot(ctx context.Context, backups []string, by, who, why string, recheck func() string, before func(id string)) (string, error) {
	for _, app := range backups {
		if _, err := h.Env.Run.Output(ctx, run.Cmd{Argv: []string{"/opt/tando/bin/tando-agent", "backup-run", app, "manual"}, Timeout: time.Hour}); err != nil {
			h.notice(ctx, "no reboot: the backup of "+app+" taken before it failed (tando backup ls -a "+app+")", false)
			return "", errors.New("the backup of " + app + " before the reboot failed: not rebooting (tando backup now -a " + app + " says why)")
		}
	}
	if len(backups) > 0 && recheck != nil {
		if r := recheck(); r != "" {
			h.notice(ctx, "no reboot: after the backups, "+r, false)
			return "", errors.New("not rebooting after the backups: " + r)
		}
	}
	id := bootID(h.Env.Proc)
	m := map[string]string{"at": i64(h.now()), "by": by, "who": who, "why": clean(why, 120), "boot_id": id, "state": "rebooting"}
	if err := h.writeMarker(m); err != nil {
		return "", err
	}
	h.audit(ctx, "host-reboot", true, "rebooting ("+by+", "+who+"): "+why)
	h.notice(ctx, "rebooting now for "+why+" ("+by+"); tando checks every app after the boot", true)
	if before != nil {
		before(id)
	}
	// --no-block: queued, systemctl returns at once (this program ends before sshd does)
	if _, err := h.Env.Run.Output(ctx, run.Cmd{Argv: []string{"systemctl", "--no-block", "reboot"}, Timeout: time.Minute}); err != nil {
		m["state"], m["result"] = "failed", "systemctl reboot failed"
		h.writeMarker(m)
		h.audit(ctx, "host-reboot", false, "systemctl reboot failed")
		return "", errors.New("systemctl reboot failed: " + clean(err.Error(), 120))
	}
	return id, nil
}

// RebootResult is the verb `reboot-result`: the last reboot by tando (the marker): state
// (rebooting, done, failed), result, secs, failed apps, boot_id.
func (h *Host) RebootResult(o *out.Writer) error {
	if err := h.needRoot(); err != nil {
		return err
	}
	b := readFile(h.rebootPath(), 64<<10)
	for _, l := range bashread.Lines(b) {
		if k, v, ok := strings.Cut(l, "="); ok {
			o.KV(k, v)
		}
	}
	o.KV("boot_now", bootID(h.Env.Proc))
	return nil
}

// AfterBoot is the verb `after-boot` (tando-host-boot.service, once per boot): after a reboot
// by tando, wait until every app answers its health check (at most 5 minutes), then tell the
// owner: "reboot done, all apps healthy in Ns", or a high-priority notice naming the apps that
// did not come back.
func (h *Host) AfterBoot(ctx context.Context, o *out.Writer) error {
	if err := h.needRoot(); err != nil {
		return err
	}
	m := loadOwn(h.rebootPath())
	if m["state"] != "rebooting" {
		o.KV("reboot", "none")
		return nil
	}
	if m["boot_id"] != "" && m["boot_id"] == bootID(h.Env.Proc) {
		o.KV("reboot", "not yet")
		return nil
	}
	failed, _ := h.verifyApps(ctx, 5*time.Minute)
	secs := h.now() - num(m["at"])
	m["done"], m["secs"] = i64(h.now()), i64(secs)
	st := loadState(h.statePath())
	if len(failed) == 0 {
		m["state"], m["result"] = "done", "ok"
		h.notice(ctx, "reboot done ("+m["why"]+"): all apps healthy "+strconv.FormatInt(secs, 10)+"s after it started", false)
		h.audit(ctx, "host-reboot", true, "done: all apps healthy in "+strconv.FormatInt(secs, 10)+"s")
		st.setNum("reboot.ok", h.now())
	} else {
		m["state"], m["result"], m["failed"] = "done", "failed", strings.Join(failed, ",")
		h.notice(ctx, "after the reboot "+plural(len(failed), "app")+" did not come back: "+list(failed, 5)+" (tando status "+failed[0]+")", false)
		h.audit(ctx, "host-reboot", false, "done, but not healthy: "+list(failed, 5))
	}
	st.del("planned")
	if l, err := h.lock(); err == nil {
		st.save(h.statePath())
		h.writeMarker(m)
		l.Release()
	}
	for k, v := range m {
		o.KV(k, v)
	}
	return nil
}

// Maintain is the verb `maintain` (tando-host-window.timer, at the start of the window): while
// the window lasts, reboot when the rules allow it (DecideReboot), with a notice lead_min
// before; a deploy in progress is waited for (every 15 minutes), `tando host care skip` cancels
// within seconds.
func (h *Host) Maintain(ctx context.Context, o *out.Writer) error {
	if err := h.needRoot(); err != nil {
		return err
	}
	for i := 0; i < 200; i++ {
		s := LoadSettings(h.confPath())
		st := loadState(h.statePath())
		planned := st.num("planned") > 0
		in, err := h.rebootInput(s, st, planned, false)
		if err != nil {
			return err
		}
		if planned { // the owner asked: no Required, Enabled or Proven needed; skip still applies
			if h.skipped() {
				return h.skipConsumed(ctx, o, st)
			}
		}
		d := DecideReboot(in)
		if !planned && in.Enabled && in.Required && in.Skip {
			return h.skipConsumed(ctx, o, st)
		}
		if d.Wait && InWindow(d.At, in.Loc, in.WindowStart, in.WindowEnd) && d.At.Sub(h.Env.Now()) <= 16*time.Minute {
			h.Sleep(d.At.Sub(h.Env.Now()))
			continue
		}
		if !d.Go {
			o.KV("reboot", "no")
			o.KV("reason", d.Reason)
			return nil
		}
		why := h.rebootWhy()
		if why == "" {
			why = "the reboot you planned"
		}
		lead := time.Duration(s.Num("lead_min")) * time.Minute
		at := h.Env.Now().Add(lead).In(in.Loc)
		if lead > 0 {
			h.notice(ctx, "rebooting at "+at.Format("15:04")+" ("+in.Loc.String()+") for "+why+"; tando host care skip cancels it", false)
			for end := h.Env.Now().Add(lead); h.Env.Now().Before(end); {
				if h.skipped() {
					return h.skipConsumed(ctx, o, st)
				}
				h.Sleep(5 * time.Second)
			}
		}
		// the rules once more: a deploy may have started during the notice
		in, err = h.rebootInput(LoadSettings(h.confPath()), loadState(h.statePath()), planned, false)
		if err != nil {
			return err
		}
		if d = DecideReboot(in); !d.Go {
			if d.Wait && InWindow(h.Env.Now().Add(15*time.Minute), in.Loc, in.WindowStart, in.WindowEnd) {
				h.notice(ctx, "reboot postponed: "+d.Reason, false)
				h.Sleep(15 * time.Minute)
				continue
			}
			h.notice(ctx, "no reboot in this window: "+d.Reason, false)
			o.KV("reboot", "no")
			o.KV("reason", d.Reason)
			return nil
		}
		by := "care"
		if planned {
			by = "planned"
		}
		recheck := func() string {
			in, err := h.rebootInput(LoadSettings(h.confPath()), loadState(h.statePath()), planned, false)
			if err != nil {
				return err.Error()
			}
			if d := DecideReboot(in); !d.Go {
				return d.Reason
			}
			return ""
		}
		if _, err := h.doReboot(ctx, d.BackupFirst, by, "tando", why, recheck, nil); err != nil {
			return err
		}
		o.KV("rebooting", "1")
		return nil
	}
	return nil
}

func (h *Host) skipConsumed(ctx context.Context, o *out.Writer, st *State) error {
	removeFile(h.skipPath())
	if l, err := h.lock(); err == nil {
		st = loadState(h.statePath())
		st.del("planned")
		st.save(h.statePath())
		l.Release()
	}
	h.notice(ctx, "the reboot was skipped (tando host care skip); the next window tries again", false)
	h.audit(ctx, "host-reboot", true, "skipped (tando host care skip)")
	o.KV("reboot", "skipped")
	return nil
}

func removeFile(p string) { os.Remove(p) }
