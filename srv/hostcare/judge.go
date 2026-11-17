package hostcare

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
)

// Finding is one row of `tando host status`: what was found, how bad, what fixes it.
type Finding struct {
	ID      string // stable: updates.security, security.exposed.tcp-5432, ...
	Section string // updates, security, health
	State   string // ok, warn, fail; unknown: cannot be determined here (not counted, not alerted)
	Title   string // the row's label
	Detail  string // one line
	Fix     string // the exact command or setting that fixes it ("" when ok)
	Auto    bool   // tando can do it (tando host update, host reboot, host care)
	Since   int64  // when it stopped being ok (0: ok)
	Rank    int    // its place in the to-do list (lower first)
}

// Alert is the judgement of one alert check (the summary file's "alert" rows).
type Alert struct {
	Check    string
	State    string // ok, bad, off
	Since    int64
	Priority string // low, normal, high
	Remind   int    // hours between reminders (0: the alerts' own remind_hours)
	Detail   string
}

// rank of a finding id's family in the to-do list: the first match wins.
var ranks = []string{"security.exposed", "health.ioerr", "health.readonly", "updates.dpkg", "updates.auto",
	"updates.security", "security.files", "updates.eol", "health.disk", "updates.reboot", "updates.kernel",
	"health.units", "health.clock", "security.ssh", "security.firewall", "updates.lists", "updates.restart",
	"updates.lock", "updates.held", "health"}

func rankOf(id, state string) int {
	r := len(ranks)
	for i, p := range ranks {
		if strings.HasPrefix(id, p) {
			r = i
			break
		}
	}
	if state == "fail" {
		return r
	}
	return 100 + r
}

// judging collects findings.
type judging struct {
	f   Facts
	s   Settings
	st  *State
	now int64
	res []Finding
}

func (j *judging) add(section, id, state, title, detail, fix string, auto bool) {
	fd := Finding{ID: id, Section: section, State: state, Title: title, Detail: clean(detail, 300)}
	if state == "warn" || state == "fail" {
		fd.Fix, fd.Auto = clean(fix, 300), auto
	}
	fd.Since = j.st.since("since."+id, state == "warn" || state == "fail", j.now)
	fd.Rank = rankOf(id, state)
	j.res = append(j.res, fd)
}

// Judge turns the facts into findings and the alert checks' states. It updates the state
// (since-times, first sightings of security updates).
func Judge(f Facts, s Settings, st *State) ([]Finding, []Alert) {
	j := &judging{f: f, s: s, st: st, now: f.At}
	seen := map[string]bool{}
	j.updates()
	j.security()
	j.health()
	for _, fd := range j.res {
		seen["since."+fd.ID] = true
	}
	for _, k := range st.keys("since.") { // findings that are gone are ok now
		if !seen[k] {
			st.del(k)
		}
	}
	return j.res, j.alerts()
}

func ago(now, t int64) string {
	if t <= 0 {
		return "never"
	}
	d := now - t
	switch {
	case d < 0:
		return "just now"
	case d < 120:
		return strconv.FormatInt(d, 10) + "s ago"
	case d < 7200:
		return strconv.FormatInt(d/60, 10) + "m ago"
	case d < 2*86400:
		return strconv.FormatInt(d/3600, 10) + "h ago"
	}
	return strconv.FormatInt(d/86400, 10) + "d ago"
}

func days(sec int64) string {
	d := sec / 86400
	if d == 1 {
		return "1 day"
	}
	if d < 1 {
		return strconv.FormatInt(sec/3600, 10) + " h"
	}
	return strconv.FormatInt(d, 10) + " days"
}

// list names the first n items and how many more.
func list(items []string, n int) string {
	if len(items) <= n {
		return strings.Join(items, ", ")
	}
	return strings.Join(items[:n], ", ") + fmt.Sprintf(" +%d more", len(items)-n)
}

func plural(n int, one string) string {
	if n == 1 {
		return "1 " + one
	}
	return strconv.Itoa(n) + " " + one + "s"
}

// secFirst keeps when each pending security update was first seen and returns the oldest.
func (j *judging) secFirst() (oldest int64, names []string) {
	pending := map[string]bool{}
	for _, p := range j.f.Apt.Security() {
		pending[p.Name] = true
		names = append(names, p.Name)
		k := "sec." + p.Name
		t := j.st.num(k)
		if t == 0 {
			t = j.now
			j.st.setNum(k, t)
		}
		if oldest == 0 || t < oldest {
			oldest = t
		}
	}
	if j.f.Apt.At > 0 {
		for _, k := range j.st.keys("sec.") {
			if !pending[strings.TrimPrefix(k, "sec.")] {
				j.st.del(k)
			}
		}
	}
	return
}

func (j *judging) updates() {
	f, a, now := j.f, j.f.Apt, j.now
	careOn := j.s["care_updates"] == "on"
	if a.At == 0 {
		why := "not checked yet: the first check runs within the hour (tando host update checks now)"
		if a.Err != "" {
			why = a.Err
		}
		j.add("updates", "updates.security", "warn", "security updates", why, "tando host update", true)
	} else {
		oldest, names := j.secFirst()
		other := len(a.Pkgs) - len(names)
		switch {
		case len(names) == 0:
			d := "none pending"
			if other > 0 {
				d += fmt.Sprintf("; %d other updates (tando host update --all)", other)
			}
			j.add("updates", "updates.security", "ok", "security updates", d, "", false)
		default:
			st := "warn"
			if now-oldest >= j.s.Num("updates_days")*86400 {
				st = "fail"
			}
			d := fmt.Sprintf("%s pending (%s), the oldest for %s", plural(len(names), "update"), list(names, 3), days(now-oldest))
			if careOn && a.UU.Enabled {
				d += "; unattended-upgrades installs them on its next run"
			}
			j.add("updates", "updates.security", st, "security updates", d, "tando host update", true)
		}
		if a.Err != "" {
			j.add("updates", "updates.apt", "warn", "apt", a.Err, "sudo apt-get update (on the server) shows why", false)
		}
	}
	// the package lists: unattended-upgrades refreshes them daily
	if a.At > 0 {
		age := now - a.ListsAt
		switch {
		case a.ListsAt == 0:
			j.add("updates", "updates.lists", "warn", "package lists", "never refreshed", "tando host update", true)
		case age > 7*86400:
			j.add("updates", "updates.lists", "fail", "package lists", "last refreshed "+ago(now, a.ListsAt)+": new security updates are not seen", "tando host update", true)
		case age > 2*86400:
			j.add("updates", "updates.lists", "warn", "package lists", "last refreshed "+ago(now, a.ListsAt), "tando host update", true)
		default:
			j.add("updates", "updates.lists", "ok", "package lists", "refreshed "+ago(now, a.ListsAt), "", false)
		}
	}
	// automatic security updates (unattended-upgrades)
	if a.At > 0 {
		u, l := a.UU, a.UULog
		on := a.UUInstalled && u.Enabled && u.Periodic && u.SecurityOrigin
		who := "Ubuntu's default"
		if careOn {
			who = "tando host care"
		}
		switch {
		case l.LastErr > 0 && l.LastErr >= l.LastOK && now-l.LastErr < 7*86400:
			j.add("updates", "updates.auto", "fail", "automatic updates", "unattended-upgrades failed "+ago(now, l.LastErr)+": "+l.Err,
				"sudo tail -50 /var/log/unattended-upgrades/unattended-upgrades.log (on the server) says why", false)
		case !on && careOn:
			j.add("updates", "updates.auto", "fail", "automatic updates", "tando host care has them on, but unattended-upgrades is "+uuWhy(a), "tando host care on --updates", true)
		case !on:
			j.add("updates", "updates.auto", "warn", "automatic updates", "off ("+uuWhy(a)+"): security updates wait for you", "tando host care on --updates", true)
		case l.LastRun > 0 && now-l.LastRun > 3*86400:
			j.add("updates", "updates.auto", "warn", "automatic updates", "on ("+who+"), but last ran "+ago(now, l.LastRun), "sudo systemctl status apt-daily-upgrade.timer (on the server)", false)
		default:
			d := "on (" + who + "), security only"
			if u.OtherOrigins {
				d = "on (" + who + "), security and other updates"
			}
			if l.LastRun > 0 {
				d += ", last run " + ago(now, l.LastRun)
			}
			j.add("updates", "updates.auto", "ok", "automatic updates", d, "", false)
		}
	}
	if len(a.Broken) > 0 || len(a.Audit) > 0 {
		names := a.Audit
		if len(names) == 0 {
			names = a.Broken
		}
		j.add("updates", "updates.dpkg", "fail", "dpkg", "an install was cut off: "+list(names, 3)+" not configured; no update installs until it is fixed",
			"tando host update (runs sudo dpkg --configure -a first)", true)
	}
	if len(a.Held) > 0 {
		j.add("updates", "updates.held", "warn", "held packages", list(a.Held, 4)+": never upgraded", "sudo apt-mark unhold "+strings.Join(a.Held[:min(len(a.Held), 4)], " ")+" (if the hold is not on purpose)", false)
	}
	since := j.st.since("lock.since", f.DpkgLockPID != 0, now)
	if f.DpkgLockPID != 0 && now-since > 3600 {
		who := "a process"
		if f.DpkgLockPID > 0 {
			who = "pid " + strconv.Itoa(f.DpkgLockPID) + " " + f.DpkgLockComm
		}
		j.add("updates", "updates.lock", "warn", "apt lock", "held by "+who+" for "+strings.TrimSuffix(ago(now, since), " ago"),
			"sudo systemctl status unattended-upgrades apt-daily-upgrade (on the server): if nothing installs, end that process", false)
	}
	if n := len(a.NR.Services); n > 0 {
		j.add("updates", "updates.restart", "warn", "old libraries", plural(n, "service")+" still run old code: "+list(a.NR.Services, 3),
			"tando host reboot (or sudo systemctl restart "+a.NR.Services[0]+")", true)
	}
	// reboot and kernel
	rs := j.st.since("seen.reboot", f.RebootRequired, now)
	switch {
	case f.RebootRequired:
		st := "warn"
		if now-rs >= j.s.Num("reboot_days")*86400 {
			st = "fail"
		}
		why := ""
		if len(f.RebootPkgs) > 0 {
			why = " (" + list(f.RebootPkgs, 3) + ")"
		}
		fix := "tando host reboot"
		if j.s["care_reboot"] == "on" {
			fix = "tando host reboot (or wait: care reboots in the window " + j.s["window"] + ")"
		}
		j.add("updates", "updates.reboot", st, "reboot", "needed since "+ago(now, rs)+why, fix, true)
	default:
		j.add("updates", "updates.reboot", "ok", "reboot", "not needed; up "+dur(f.Uptime), "", false)
	}
	switch {
	case f.KernelNewest == "":
		j.add("updates", "updates.kernel", "unknown", "kernel", f.Kernel+": cannot tell if newer is installed (no kernel in /boot: a container or a provider's kernel)", "", false)
	case f.KernelNewest != f.Kernel && !versionLess(f.KernelNewest, f.Kernel):
		j.add("updates", "updates.kernel", "warn", "kernel", "running "+f.Kernel+", installed "+f.KernelNewest+": a reboot loads it", "tando host reboot", true)
	default:
		j.add("updates", "updates.kernel", "ok", "kernel", f.Kernel+", the newest installed", "", false)
	}
	j.eol()
}

func uuWhy(a AptFacts) string {
	switch {
	case !a.UUInstalled:
		return "not installed"
	case !a.UU.Periodic:
		return "APT::Periodic is disabled"
	case !a.UU.Enabled:
		return "disabled"
	case !a.UU.SecurityOrigin:
		return "not set up for security updates"
	}
	return "off"
}

func (j *judging) eol() {
	f := j.f
	name := f.OSName
	if name == "" {
		name = "unknown system"
	}
	end, ok := EOL(f.OSID, f.OSVersion)
	switch {
	case f.OSID != "ubuntu":
		j.add("updates", "updates.eol", "ok", "support", name+": end of support not tracked by tando", "", false)
	case !ok:
		j.add("updates", "updates.eol", "warn", "support", name+": end of support unknown to this tando (a newer release?)",
			"update tando on the laptop, then tando host setup", false)
	case end.Unix() < j.now:
		j.add("updates", "updates.eol", "fail", "support", name+": standard support ended "+end.Format("2006-01-02")+"; no more security updates",
			"sudo do-release-upgrade (on the server, after a backup), or Ubuntu Pro (sudo pro attach) for ESM security updates", false)
	case end.Unix()-j.now < j.s.Num("eol_days")*86400:
		j.add("updates", "updates.eol", "warn", "support", name+": standard support ends "+end.Format("2006-01-02")+" (in "+days(end.Unix()-j.now)+")",
			"plan sudo do-release-upgrade (on the server, after a backup), or Ubuntu Pro (sudo pro attach)", false)
	default:
		j.add("updates", "updates.eol", "ok", "support", name+", supported until "+end.Format("2006-01-02"), "", false)
	}
}

func (j *judging) security() {
	f := j.f
	var expected []string
	for _, l := range f.Listeners {
		id := "security.exposed." + l.Proto + "-" + strconv.Itoa(l.Port)
		who := l.Comm
		if l.Unit != "" {
			who += " (" + l.Unit + ")"
		}
		if who == "" {
			who = "unknown process"
		}
		switch l.Class {
		case "exposed":
			d := fmt.Sprintf("%s %s on %s listens to the world", l.Key(), who, l.Addr)
			if l.Why != "" {
				d += "; " + l.Why
			}
			fix := "bind it to 127.0.0.1, or close it: sudo ufw deny " + strconv.Itoa(l.Port) + "/" + l.Proto + "; if it is meant to be open: tando alerts set allow_ports=" + l.Key()
			j.add("security", id, "fail", "open port", d, fix, false)
		case "blocked":
			j.add("security", id, "ok", "open port", fmt.Sprintf("%s %s on %s: %s", l.Key(), who, l.Addr, l.Why), "", false)
		default:
			expected = append(expected, fmt.Sprintf("%d/%s %s", l.Port, l.Proto, firstNonEmpty(l.Why, who)))
		}
	}
	sort.Strings(expected)
	expected = uniq(expected)
	if len(expected) == 0 {
		expected = []string{"nothing outside loopback"}
	}
	j.add("security", "security.listening", "ok", "listening", list(expected, 4), "", false)
	fw := f.Firewall
	switch {
	case fw.Ufw && fw.UfwDeny, fw.NftDrop:
		j.add("security", "security.firewall", "ok", "firewall", fw.Describe(), "", false)
	default:
		port := 22
		if len(f.SSH.Ports) > 0 {
			port = f.SSH.Ports[0]
		}
		j.add("security", "security.firewall", "warn", "firewall", fw.Describe()+" (a provider's firewall is not seen from here)",
			fmt.Sprintf("sudo ufw allow %d/tcp && sudo ufw allow 80,443/tcp && sudo ufw enable (on the server; keep %d open or ssh is locked out)", port, port), false)
	}
	// ssh
	if f.SSHErr != "" {
		j.add("security", "security.ssh", "warn", "ssh", f.SSHErr, "sudo sshd -t (on the server) says what is wrong", false)
	} else {
		s := f.SSH
		keys := "no user has an authorized key"
		if len(f.KeyUsers) > 0 {
			keys = "keys: " + list(f.KeyUsers, 3)
		}
		switch {
		case s.EmptyPasswords:
			j.add("security", "security.ssh.login", "fail", "ssh login", "PermitEmptyPasswords yes: an account without a password logs in",
				"echo 'PermitEmptyPasswords no' | sudo tee /etc/ssh/sshd_config.d/60-tando-hardening.conf && sudo systemctl reload ssh", false)
		case s.Password || s.KbdInteractive:
			j.add("security", "security.ssh.login", "warn", "ssh login", "passwords accepted ("+keys+"): passwords can be guessed, keys cannot",
				"after checking that your key logs in: printf 'PasswordAuthentication no\\nKbdInteractiveAuthentication no\\n' | sudo tee /etc/ssh/sshd_config.d/60-tando-hardening.conf && sudo systemctl reload ssh", false)
		default:
			j.add("security", "security.ssh.login", "ok", "ssh login", "keys only ("+keys+")", "", false)
		}
		if s.PermitRoot == "yes" {
			j.add("security", "security.ssh.root", "warn", "ssh root", "root may log in with a password",
				"echo 'PermitRootLogin prohibit-password' | sudo tee /etc/ssh/sshd_config.d/61-tando-root.conf && sudo systemctl reload ssh", false)
		}
		guard := ""
		for _, u := range guardUnits {
			if f.Units[u] == "active" {
				guard = strings.TrimSuffix(u, ".service")
			}
		}
		if guard == "" && len(s.Ports) > 0 && fw.Limits(s.Ports[0]) {
			guard = "ufw limit"
		}
		n := f.Events.SSHFail
		d := plural(n, "failed login") + " in 24 h"
		switch {
		case guard != "":
			j.add("security", "security.ssh.fails", "ok", "ssh attempts", d+", slowed down by "+guard, "", false)
		case (s.Password || s.KbdInteractive) && n >= 20:
			j.add("security", "security.ssh.fails", "warn", "ssh attempts", d+" and nothing slows them down, with passwords accepted",
				"turn off password login (above), or: sudo apt install fail2ban", false)
		default:
			j.add("security", "security.ssh.fails", "ok", "ssh attempts", d, "", false)
		}
	}
	if len(f.EmptyPw) > 0 {
		j.add("security", "security.accounts", "warn", "accounts", "an empty password: "+list(f.EmptyPw, 3), "sudo passwd -l "+f.EmptyPw[0], false)
	}
	if len(f.Nopasswd) > 0 {
		j.add("security", "security.sudo", "ok", "sudo", "without a password: "+list(f.Nopasswd, 3)+" (tando logs in as one of them)", "", false)
	}
	var bad []string
	bad = append(bad, f.SecretModes...)
	switch {
	case len(bad) > 0:
		p, _, _ := strings.Cut(bad[0], " ")
		j.add("security", "security.files", "fail", "tando files", "readable by others: "+list(bad, 2), "sudo chmod go-rwx "+p, false)
	case f.Apt.WWCount > 0:
		j.add("security", "security.files", "fail", "tando files", plural(f.Apt.WWCount, "file")+" under "+j.f.root()+" any user may change: "+list(f.Apt.WW, 2),
			"sudo chmod o-w "+f.Apt.WW[0], false)
	default:
		j.add("security", "security.files", "ok", "tando files", "secrets root-only; nothing world-writable", "", false)
	}
}

func (f Facts) root() string { return "/opt/tando" }

func (j *judging) health() {
	f, now := j.f, j.now
	var tandoFailed, other []string
	for _, u := range f.Failed {
		if strings.HasPrefix(u, "tando-") {
			tandoFailed = append(tandoFailed, u)
		} else {
			other = append(other, u)
		}
	}
	switch {
	case len(other) > 0:
		d := plural(len(other), "unit") + " failed: " + list(other, 3)
		if len(tandoFailed) > 0 {
			d += "; and tando's " + list(tandoFailed, 2) + " (tando ls)"
		}
		j.add("health", "health.units", "fail", "services", d, "sudo systemctl status "+other[0]+" (on the server); once fixed: sudo systemctl reset-failed", false)
	case len(tandoFailed) > 0:
		j.add("health", "health.units", "warn", "services", "tando units failed: "+list(tandoFailed, 3), "tando ls (tando alerts reports apps that are down)", false)
	default:
		st := f.SystemState
		if st == "" {
			st = "unknown"
		}
		j.add("health", "health.units", "ok", "services", "none failed (systemd: "+st+")", "", false)
	}
	if len(f.ReadOnly) > 0 {
		j.add("health", "health.readonly", "fail", "file systems", list(f.ReadOnly, 3)+" mounted read-only (not so in /etc/fstab): usually after disk errors",
			"sudo journalctl -k -p err -b (on the server); after checking the disk: sudo mount -o remount,rw "+f.ReadOnly[0], false)
	}
	if f.Events.IOErr > 0 {
		j.add("health", "health.ioerr", "fail", "disk errors", plural(f.Events.IOErr, "I/O error")+" in the kernel log in 24 h: "+f.Events.IOErrLast,
			"take a backup now (tando backup now), then sudo journalctl -k -p err --since -24h; ask your provider about the disk", false)
	} else {
		j.add("health", "health.ioerr", "ok", "disk errors", "none in the kernel log in 24 h", "", false)
	}
	for _, d := range f.Disks {
		id := "health.disk" + strings.ReplaceAll(d.Mount, "/", ".")
		if d.Mount == "/" {
			id = "health.disk.root"
		}
		pct := max(d.Pct, d.InodePct)
		what := fmt.Sprintf("%d%% used, %s free", d.Pct, size(d.FreeKB*1024))
		if d.InodePct >= 50 {
			what += fmt.Sprintf(", inodes %d%%", d.InodePct)
		}
		limit, fix, auto := int64(90), "sudo du -xh "+d.Mount+" | sort -h | tail (on the server) shows what takes the space", false
		if d.Mount == "/boot" {
			limit, fix, auto = j.s.Num("boot_pct"), "tando host update (removes old kernels with apt-get autoremove)", true
			what += ": kernel updates need room here"
		}
		st := "ok"
		switch {
		case int64(pct) >= 97 || (d.Mount == "/boot" && int64(pct) >= limit):
			st = "fail"
		case int64(pct) >= limit:
			st = "warn"
		}
		j.add("health", id, st, "disk "+d.Mount, what, fix, auto)
	}
	// memory, swap, load: tando alerts already alerts on them; shown here as they are
	mem := "memory"
	if f.MemTotal > 0 {
		used := f.MemTotal - f.MemAvail
		mem = fmt.Sprintf("%s of %s used", size(used*1024), size(f.MemTotal*1024))
		if f.SwapTotal > 0 {
			mem += fmt.Sprintf(", swap %d%%", (f.SwapTotal-f.SwapFree)*100/f.SwapTotal)
		} else {
			mem += ", no swap"
		}
		if f.PSIMem.Known {
			mem += fmt.Sprintf(", pressure %.1f%%", f.PSIMem.Some60)
		}
		st := "ok"
		if f.MemAvail*100 < f.MemTotal*5 || f.PSIMem.Some60 >= 30 {
			st = "warn"
		}
		if container(f.Virt) { // /proc/meminfo and PSI may be the host's, not this container's
			st, mem = "unknown", mem+" (as /proc says in a "+f.Virt+" container: may be the host's)"
		}
		j.add("health", "health.memory", st, "memory", mem, "tando top shows what uses it", false)
	}
	if f.Load5 != "" {
		l, _ := strconv.ParseFloat(f.Load5, 64)
		st, d := "ok", fmt.Sprintf("%s (5 min) on %s", f.Load5, plural(f.CPUs, "CPU"))
		if f.PSICPU.Known {
			d += fmt.Sprintf(", cpu pressure %.1f%%", f.PSICPU.Some60)
		}
		if l >= float64(f.CPUs) {
			st = "warn"
		}
		if container(f.Virt) { // /proc/loadavg is the host kernel's in a container
			st, d = "unknown", d+" (the host's load: a "+f.Virt+" container)"
		}
		j.add("health", "health.load", st, "load", d, "tando top shows what uses it", false)
	}
	// the clock
	unsync := f.Clock.Known && !f.Clock.Synced && !container(f.Virt)
	us := j.st.since("clock.unsync", unsync, now)
	switch {
	case !f.Clock.Known:
		j.add("health", "health.clock", "unknown", "clock", "synchronisation cannot be read here", "", false)
	case container(f.Virt):
		j.add("health", "health.clock", "unknown", "clock", "kept by the host ("+f.Virt+" container): not judged here", "", false)
	case unsync && f.Clock.NTP == "":
		j.add("health", "health.clock", "fail", "clock", "not synchronised, and no time service runs", "sudo timedatectl set-ntp true (on the server)", false)
	case unsync && now-us >= j.s.Num("clock_min")*60:
		j.add("health", "health.clock", "fail", "clock", "not synchronised for "+strings.TrimSuffix(ago(now, us), " ago")+" ("+f.Clock.NTP+" runs)",
			"timedatectl timesync-status (on the server): is NTP (udp 123) blocked?", false)
	case unsync:
		j.add("health", "health.clock", "warn", "clock", "not synchronised yet ("+f.Clock.NTP+")", "wait a few minutes; timedatectl (on the server)", false)
	default:
		n := f.Clock.NTP
		if n == "" {
			n = "a time service"
		}
		j.add("health", "health.clock", "ok", "clock", "synchronised ("+strings.TrimSuffix(n, ".service")+")", "", false)
	}
	if f.Zombies > 20 {
		j.add("health", "health.zombies", "warn", "processes", strconv.Itoa(f.Zombies)+" zombie processes: a parent does not reap its children", "ps -eo ppid,stat,comm | awk '$2 ~ /Z/' (on the server) names the parent", false)
	}
	if f.Events.OOM > 0 {
		j.add("health", "health.oom", "warn", "out of memory", plural(f.Events.OOM, "process")+" killed by the kernel in 24 h", "tando alerts and tando top say which", false)
	}
	if f.JournalBytes > 0 {
		st := "ok"
		var root int64
		for _, d := range f.Disks {
			if d.Mount == "/" || d.Mount == "/var" {
				root = max(root, d.TotalKB*1024)
			}
		}
		if root > 0 && f.JournalBytes*100 > root*15 {
			st = "warn"
		}
		j.add("health", "health.journal", st, "journal", size(f.JournalBytes)+" of system logs", "sudo journalctl --vacuum-size=500M (on the server)", false)
	}
	var stale, okb []string
	hours := f.BackupHours
	if hours <= 0 {
		hours = 50
	}
	for _, b := range f.Backups {
		if now-b.Since > hours*3600 {
			w := b.App + " " + strings.TrimSuffix(ago(now, b.Since), " ago")
			if b.Last == 0 {
				w = b.App + " none yet"
			}
			stale = append(stale, w)
		} else {
			okb = append(okb, b.App+" "+ago(now, b.Last))
		}
	}
	switch {
	case len(stale) > 0:
		j.add("health", "health.backups", "warn", "backups", "older than "+strconv.FormatInt(hours, 10)+" h: "+list(stale, 3), "tando backup now -a "+strings.Fields(stale[0])[0]+" (tando alerts says why the daily one failed)", false)
	case len(okb) > 0:
		j.add("health", "health.backups", "ok", "backups", list(okb, 3), "", false)
	}
}

// container: systemd's Virtualization for a container (the clock is its host's to keep).
func container(v string) bool {
	switch v {
	case "docker", "podman", "lxc", "lxc-libvirt", "systemd-nspawn", "rkt", "wsl", "proot", "pouch", "container-other", "openvz":
		return true
	}
	return false
}

func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

func uniq(s []string) []string {
	var res []string
	for i, x := range s {
		if i == 0 || x != s[i-1] {
			res = append(res, x)
		}
	}
	return res
}

// size in B, KB, MB, GB (powers of 1024, one decimal under 10).
func size(b int64) string {
	u := []string{"B", "KB", "MB", "GB", "TB"}
	f := float64(b)
	i := 0
	for f >= 1024 && i < len(u)-1 {
		f /= 1024
		i++
	}
	if f < 10 && i > 0 {
		return fmt.Sprintf("%.1f %s", f, u[i])
	}
	return fmt.Sprintf("%.0f %s", f, u[i])
}

// dur: seconds as "3d 4h", "5h 02m", "12m".
func dur(s int64) string {
	switch {
	case s < 3600:
		return strconv.FormatInt(s/60, 10) + "m"
	case s < 86400:
		return fmt.Sprintf("%dh %02dm", s/3600, s%3600/60)
	}
	return fmt.Sprintf("%dd %dh", s/86400, s%86400/3600)
}

// alerts judges the alert checks from the findings' facts, with their thresholds (the findings
// warn earlier; an alert is what is worth a message).
func (j *judging) alerts() []Alert {
	f, s, now := j.f, j.s, j.now
	find := func(id string) *Finding {
		for i := range j.res {
			if j.res[i].ID == id {
				return &j.res[i]
			}
		}
		return nil
	}
	var res []Alert
	add := func(check string, bad bool, prio string, remind int, detail string) {
		a := Alert{Check: check, Priority: prio, Remind: remind}
		switch {
		case !s.On(check):
			a.State = "off"
			j.st.del("alert." + check)
		case bad:
			a.State, a.Detail = "bad", clean(detail, 300)
			a.Since = j.st.since("alert."+check, true, now)
		default:
			a.State = "ok"
			j.st.del("alert." + check)
		}
		res = append(res, a)
	}
	// updates: security updates waiting longer than updates_days, unattended-upgrades failing, dpkg broken
	upd, det := false, ""
	if x := find("updates.security"); x != nil && x.State == "fail" {
		upd, det = true, x.Detail+": tando host update"
	}
	if x := find("updates.auto"); x != nil && x.State == "fail" {
		upd, det = true, joinDetail(det, x.Detail)
	}
	if x := find("updates.dpkg"); x != nil {
		upd, det = true, joinDetail(det, x.Detail+": "+x.Fix)
	}
	add("updates", upd, "normal", 0, det)
	r := find("updates.reboot")
	add("reboot", r != nil && r.State == "fail", "normal", 24, "reboot "+detailOf(r)+": tando host reboot")
	var exp []string
	for _, l := range f.Listeners {
		if l.Class == "exposed" {
			exp = append(exp, l.Key()+" "+firstNonEmpty(l.Comm, "?"))
		}
	}
	add("exposed", len(exp) > 0, "high", 0, "open to the world: "+list(exp, 3)+"; tando host status says how to close it")
	sl := find("security.ssh.login")
	sr := find("security.ssh.root")
	sshBad := (sl != nil && sl.State != "ok") || sr != nil
	sd := ""
	if sl != nil && sl.State != "ok" {
		sd = sl.Detail
	}
	if sr != nil {
		sd = joinDetail(sd, sr.Detail)
	}
	add("ssh", sshBad, "low", 24, sd+"; tando host status shows the fix")
	var units []string
	for _, u := range f.Failed {
		if !strings.HasPrefix(u, "tando-") {
			units = append(units, u)
		}
	}
	add("units", len(units) > 0, "normal", 0, plural(len(units), "unit")+" failed: "+list(units, 3))
	add("readonly", len(f.ReadOnly) > 0, "high", 0, list(f.ReadOnly, 3)+" mounted read-only")
	add("ioerr", f.Events.IOErr > 0, "high", 0, plural(f.Events.IOErr, "disk I/O error")+" in 24 h: "+f.Events.IOErrLast)
	c := find("health.clock")
	add("clock", c != nil && c.State == "fail", "normal", 0, "clock "+detailOf(c))
	e := find("updates.eol")
	end, known := EOL(f.OSID, f.OSVersion)
	add("eol", known && end.Unix()-now < s.Num("eol_days")*86400, "normal", 24*7, detailOf(e))
	var boot string
	for _, d := range f.Disks {
		if d.Mount == "/boot" && int64(max(d.Pct, d.InodePct)) >= s.Num("boot_pct") {
			boot = fmt.Sprintf("/boot is %d%% full: kernel updates fail; tando host update removes old kernels", max(d.Pct, d.InodePct))
		}
	}
	add("boot", boot != "", "normal", 0, boot)
	return res
}

func joinDetail(a, b string) string {
	if a == "" {
		return b
	}
	return a + "; " + b
}

func detailOf(f *Finding) string {
	if f == nil {
		return ""
	}
	return f.Detail
}
