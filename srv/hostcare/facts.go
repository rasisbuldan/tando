package hostcare

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"

	"tando/srv/internal/decimal"
	"tando/srv/internal/kvfile"
	"tando/srv/internal/run"
	"tando/srv/internal/systemd"
	"tando/srv/internal/valid"
)

// Facts are what one run learned about the host. The cheap ones are read every run (files, a
// few programs); Apt comes from the cache of the slow pass (at most every apt_hours).
type Facts struct {
	At                                          int64
	Hostname, OSID, OSVersion, OSName, Codename string
	Kernel, Arch, Virt                          string
	Uptime                                      int64
	CPUs                                        int
	Load1, Load5                                string
	MemTotal, MemAvail, SwapTotal, SwapFree     int64 // kB
	PSIMem, PSICPU, PSIIO                       PSI
	Disks                                       []Disk
	ReadOnly                                    []string // mounted read-only, but not so in /etc/fstab
	RebootRequired                              bool
	RebootSince                                 int64
	RebootPkgs                                  []string
	KernelNewest                                string // newest installed kernel (/boot, else dpkg)
	SSH                                         SSHD
	SSHErr                                      string
	KeyUsers                                    []string // "vmadmin 2": users with authorized keys, and how many
	EmptyPw                                     []string // accounts with an empty password
	Nopasswd                                    []string // users with NOPASSWD sudo (information)
	Firewall                                    Firewall
	Listeners                                   []Listener
	Failed                                      []string // failed units
	SystemState                                 string   // running, degraded, ...
	Units                                       map[string]string
	Clock                                       ClockFacts
	Zombies                                     int
	Backups                                     []AppBackup
	JournalBytes                                int64
	DpkgLockPID                                 int
	DpkgLockComm                                string
	CaddyOurs                                   bool
	SecretModes                                 []string // tando files readable by others that must not be
	Events                                      Events   // kernel and ssh log events in the last 24 h
	Apt                                         AptFacts
	BackupHours                                 int64
	GuardedUIDs                                 map[int]bool
}

// Disk is one file system that matters for updates: /, /var, /boot.
type Disk struct {
	Mount            string
	Pct, InodePct    int
	TotalKB, UsedKB  int64
	FreeKB           int64
	FileSystemOfPath string
}

// ClockFacts: whether the kernel clock is synchronised (adjtimex), and by which service.
type ClockFacts struct {
	Synced, Known bool
	NTP           string // the active time service unit, or ""
}

// AppBackup is an app with daily backups and when its last one was taken.
type AppBackup struct {
	App   string
	Last  int64 // 0: none yet (counted from the app's creation)
	Since int64 // what the age is counted from
}

// Events are the kernel's and sshd's log events of the last 24 hours (from the state's hourly
// counts, fed by the journal since the last run).
type Events struct {
	IOErr, OOM, SSHFail int
	IOErrLast           string
}

// timeUnits are asked for their state in one `systemctl show` call.
var timeUnits = []string{"systemd-timesyncd.service", "chrony.service", "chronyd.service", "ntp.service", "ntpsec.service", "openntpd.service"}
var guardUnits = []string{"fail2ban.service", "sshguard.service", "crowdsec.service"}
var otherUnits = []string{"ufw.service", "nftables.service", "apt-daily.timer", "apt-daily-upgrade.timer", "unattended-upgrades.service",
	"tandod.service", "tando-watch.timer", "tando-host.timer", "caddy.service", "ssh.service", "ssh.socket"}

// Collect reads the facts. apt: also the slow pass (apt-get -s, dpkg, needrestart), else its
// cache. st is the state, whose event counts and journal cursor the run updates.
func (h *Host) Collect(ctx context.Context, st *State, s Settings, apt bool) Facts {
	f := Facts{At: h.now(), Units: map[string]string{}}
	h.machine(&f)
	h.disks(&f)
	f.RebootSince = mtime(h.p("/run/reboot-required"))
	f.RebootRequired = f.RebootSince > 0
	for _, l := range lines(readFile(h.p("/run/reboot-required.pkgs"), 64<<10), 200) {
		if pkgName(l) {
			f.RebootPkgs = append(f.RebootPkgs, l)
		}
	}
	f.KernelNewest = h.newestKernel()
	h.systemd(ctx, &f)
	h.sshd(ctx, &f)
	h.accounts(&f)
	f.Firewall = h.firewall(ctx, f.Units)
	f.GuardedUIDs = h.guardedUIDs()
	f.Listeners = h.listeners()
	classify(f.Listeners, f.SSH, f.Firewall, f.GuardedUIDs, s.AllowedPorts())
	h.journal(ctx, st, &f)
	f.Clock.Synced, f.Clock.Known = h.Adjtimex()
	for _, u := range timeUnits {
		if f.Units[u] == "active" {
			f.Clock.NTP = u
		}
	}
	f.Zombies = h.zombies()
	f.BackupHours = watchSetting(readFile(filepath.Join(h.Env.Root, "alerts.conf"), 1<<20), "backup_hours", 50)
	f.Backups = h.backups()
	f.JournalBytes = dirBytes(h.p("/var/log/journal"), 2)
	f.DpkgLockPID = dpkgLockHolder(h.p("/var/lib/dpkg/lock-frontend"))
	if f.DpkgLockPID > 0 {
		f.DpkgLockComm = clean(strings.TrimSpace(string(readFile(filepath.Join(h.Env.Proc, strconv.Itoa(f.DpkgLockPID), "comm"), 64))), 32)
	}
	f.CaddyOurs = h.caddyOurs()
	f.SecretModes = h.secretModes()
	f.Nopasswd = h.nopasswd()
	f.Apt = h.aptFacts(ctx, s, apt)
	if f.KernelNewest == "" && len(f.Apt.Kernels) > 0 {
		f.KernelNewest = f.Apt.Kernels[len(f.Apt.Kernels)-1]
	}
	return f
}

func (h *Host) machine(f *Facts) {
	os := ParseOSRelease(readFile(h.p("/etc/os-release"), 64<<10))
	f.OSID, f.OSVersion, f.Codename = clean(os["ID"], 20), clean(os["VERSION_ID"], 20), clean(os["VERSION_CODENAME"], 20)
	f.OSName = clean(os["PRETTY_NAME"], 60)
	f.Hostname = clean(strings.TrimSpace(string(readFile(filepath.Join(h.Env.Proc, "sys/kernel/hostname"), 256))), 64)
	f.Kernel = clean(strings.TrimSpace(string(readFile(filepath.Join(h.Env.Proc, "sys/kernel/osrelease"), 256))), 64)
	f.Arch = map[string]string{"amd64": "x86_64", "arm64": "aarch64"}[runtime.GOARCH]
	if u := strings.Fields(string(readFile(filepath.Join(h.Env.Proc, "uptime"), 256))); len(u) > 0 {
		x, _, _ := strings.Cut(u[0], ".")
		f.Uptime, _ = decimal.Parse(x, 12)
	}
	if l := strings.Fields(string(readFile(filepath.Join(h.Env.Proc, "loadavg"), 256))); len(l) >= 2 {
		f.Load1, f.Load5 = clean(l[0], 10), clean(l[1], 10)
	}
	f.CPUs = cpusOnline(strings.TrimSpace(string(readFile(h.p("/sys/devices/system/cpu/online"), 256))))
	if f.CPUs == 0 {
		f.CPUs = runtime.NumCPU()
	}
	m := ParseMeminfo(readFile(filepath.Join(h.Env.Proc, "meminfo"), 64<<10))
	f.MemTotal, f.MemAvail, f.SwapTotal, f.SwapFree = m["MemTotal"], m["MemAvailable"], m["SwapTotal"], m["SwapFree"]
	f.PSIMem = ParsePSI(readFile(filepath.Join(h.Env.Proc, "pressure/memory"), 4096))
	f.PSICPU = ParsePSI(readFile(filepath.Join(h.Env.Proc, "pressure/cpu"), 4096))
	f.PSIIO = ParsePSI(readFile(filepath.Join(h.Env.Proc, "pressure/io"), 4096))
}

// cpusOnline counts "0-3,5" (the kernel's list).
func cpusOnline(s string) int {
	n := 0
	for _, part := range strings.Split(s, ",") {
		lo, hi, rng := strings.Cut(part, "-")
		a, ok := decimal.Parse(lo, 5)
		if !ok {
			continue
		}
		b := a
		if rng {
			if b, ok = decimal.Parse(hi, 5); !ok {
				continue
			}
		}
		n += int(b - a + 1)
	}
	return n
}

// disks: /, /var and /boot (each file system once, named by its mount point), and the file
// systems that are read-only although /etc/fstab does not say so.
func (h *Host) disks(f *Facts) {
	mounts := ParseMounts(readFile(filepath.Join(h.Env.Proc, "mounts"), 4<<20))
	seen := map[string]bool{}
	for _, p := range []string{"/", "/var", "/boot"} {
		mp := mountOf(mounts, p)
		if seen[mp] {
			continue
		}
		seen[mp] = true
		fs, err := h.Statfs(h.p(p))
		if err != nil || fs.Blocks == 0 {
			continue
		}
		d := Disk{Mount: mp, TotalKB: int64(fs.KiB(fs.Blocks)), FreeKB: int64(fs.KiB(fs.Avail))}
		d.UsedKB = int64(fs.KiB(fs.Blocks - fs.Free))
		if d.UsedKB+d.FreeKB > 0 {
			d.Pct = int((d.UsedKB*100 + d.UsedKB + d.FreeKB - 1) / (d.UsedKB + d.FreeKB)) // df's rounding up
		}
		if fs.Files > 0 {
			used := fs.Files - fs.FilesFree
			d.InodePct = int((used*100 + fs.Files - 1) / fs.Files)
		}
		f.Disks = append(f.Disks, d)
	}
	fstab := map[string]bool{}
	for _, m := range ParseMounts(readFile(h.p("/etc/fstab"), 1<<20)) {
		fstab[m.Dir] = m.ro()
	}
	disk := map[string]bool{"ext2": true, "ext3": true, "ext4": true, "xfs": true, "btrfs": true, "f2fs": true, "jfs": true, "reiserfs": true}
	for _, m := range mounts {
		if !disk[m.Type] || !m.ro() || fstab[m.Dir] || strings.HasPrefix(m.Dir, "/snap/") {
			continue
		}
		// a bind mount of a single file (a container's /etc/hosts) is not a file system to repair
		if fi, err := os.Stat(h.p(m.Dir)); err == nil && !fi.IsDir() {
			continue
		}
		if len(f.ReadOnly) < 20 {
			f.ReadOnly = append(f.ReadOnly, clean(m.Dir, 80))
		}
	}
}

// mountOf is the mount point of path: the longest mounted directory that contains it.
func mountOf(ms []Mount, p string) string {
	best := "/"
	for _, m := range ms {
		d := m.Dir
		if (p == d || strings.HasPrefix(p, strings.TrimSuffix(d, "/")+"/")) && len(d) > len(best) {
			best = d
		}
	}
	return best
}

// newestKernel: the newest /boot/vmlinuz-<version> (a container has none).
func (h *Host) newestKernel() string {
	ents, _ := os.ReadDir(h.p("/boot"))
	var v []string
	for _, e := range ents {
		if k, ok := strings.CutPrefix(e.Name(), "vmlinuz-"); ok && k != "" && k[0] >= '0' && k[0] <= '9' {
			v = append(v, k)
		}
	}
	if len(v) == 0 {
		return ""
	}
	SortVersions(v)
	return clean(v[len(v)-1], 64)
}

// systemd: the manager's state (degraded?), the failed units and the units host care asks about.
func (h *Host) systemd(ctx context.Context, f *Facts) {
	b, err := h.Env.Run.Output(ctx, run.Cmd{Argv: []string{"systemctl", "show", "-p", "SystemState,NFailedUnits,Virtualization"}, Timeout: 10 * time.Second})
	nfailed := int64(0)
	if err == nil {
		for _, l := range lines(b, 50) {
			k, v, _ := strings.Cut(l, "=")
			switch k {
			case "SystemState":
				f.SystemState = clean(v, 20)
			case "NFailedUnits":
				nfailed, _ = decimal.Parse(v, 6)
			case "Virtualization":
				f.Virt = clean(v, 20)
			}
		}
	}
	units := append(append(append([]string{}, timeUnits...), guardUnits...), otherUnits...)
	if res, err := systemd.Show(ctx, h.Env.Run, units, "ActiveState"); err == nil {
		for i, u := range units {
			f.Units[u] = res[i]["ActiveState"]
		}
	}
	if nfailed > 0 {
		b, err := h.Env.Run.Output(ctx, run.Cmd{Argv: []string{"systemctl", "list-units", "--state=failed", "--plain", "--no-legend", "--no-pager", "--full"}, Timeout: 10 * time.Second})
		if err == nil {
			for _, u := range ParseFailedUnits(b) {
				f.Failed = append(f.Failed, clean(u, 100))
			}
		}
	}
}

// sshd: `sshd -T`, the configuration sshd would use (drop-ins and Match defaults resolved).
func (h *Host) sshd(ctx context.Context, f *Facts) {
	if fi, err := os.Stat(h.p("/usr/sbin/sshd")); err != nil || !fi.Mode().IsRegular() {
		f.SSHErr = "sshd is not installed"
		return
	}
	b, err := h.Env.Run.Output(ctx, run.Cmd{Argv: []string{"/usr/sbin/sshd", "-T"}, Timeout: 10 * time.Second})
	if err != nil {
		f.SSHErr = clean("sshd -T failed: "+err.Error(), 160)
		return
	}
	f.SSH = ParseSshdT(b)
	if !f.SSH.Found {
		f.SSHErr = "sshd -T printed no settings"
	}
}

// accounts: users with authorized ssh keys (count per user; tando's deploy users are the CI's,
// listed by tando ci ls), accounts with an empty password, NOPASSWD sudo rules.
func (h *Host) accounts(f *Facts) {
	type user struct{ name, home, shell string }
	var users []user
	for _, l := range lines(readFile(h.p("/etc/passwd"), 4<<20), 20000) {
		p := strings.Split(l, ":")
		if len(p) < 7 || p[0] == "" {
			continue
		}
		users = append(users, user{p[0], p[5], p[6]})
	}
	patterns := f.SSH.KeyFiles
	if len(patterns) == 0 {
		patterns = []string{".ssh/authorized_keys", ".ssh/authorized_keys2"}
	}
	for _, u := range users {
		if strings.HasPrefix(u.name, "tando-") || u.home == "" || u.home == "/" || strings.HasSuffix(u.shell, "nologin") || strings.HasSuffix(u.shell, "/false") {
			continue
		}
		n := 0
		seen := map[string]bool{}
		for _, pat := range patterns {
			p := strings.NewReplacer("%h", u.home, "%u", u.name, "%%", "%").Replace(pat)
			if !strings.HasPrefix(p, "/") {
				p = u.home + "/" + p
			}
			if seen[p] || strings.Contains(p, "%") {
				continue
			}
			seen[p] = true
			for _, l := range lines(readFile(h.p(filepath.Clean(p)), 1<<20), 5000) {
				if l = strings.TrimSpace(l); l != "" && !strings.HasPrefix(l, "#") {
					n++
				}
			}
		}
		if n > 0 {
			f.KeyUsers = append(f.KeyUsers, clean(u.name, 32)+" "+strconv.Itoa(n))
		}
	}
	for _, l := range lines(readFile(h.p("/etc/shadow"), 4<<20), 20000) {
		p := strings.Split(l, ":")
		if len(p) > 1 && p[0] != "" && p[1] == "" && len(f.EmptyPw) < 20 {
			f.EmptyPw = append(f.EmptyPw, clean(p[0], 32))
		}
	}
}

// nopasswd: who may sudo without a password (information: tando needs it for its admin user).
// tando's own deploy-user rules (tando-d-*) are left out.
func (h *Host) nopasswd() []string {
	files := []string{h.p("/etc/sudoers")}
	ents, _ := os.ReadDir(h.p("/etc/sudoers.d"))
	for _, e := range ents {
		if !strings.Contains(e.Name(), ".") && !strings.HasSuffix(e.Name(), "~") {
			files = append(files, filepath.Join(h.p("/etc/sudoers.d"), e.Name()))
		}
	}
	seen := map[string]bool{}
	var res []string
	for _, fl := range files {
		for _, l := range lines(readFile(fl, 1<<20), 5000) {
			l = strings.TrimSpace(l)
			if l == "" || strings.HasPrefix(l, "#") || !strings.Contains(l, "NOPASSWD") {
				continue
			}
			who := strings.Fields(l)[0]
			if strings.HasPrefix(who, "tando-") || strings.HasPrefix(who, "Defaults") || strings.HasPrefix(who, "Cmnd_Alias") || seen[who] {
				continue
			}
			seen[who] = true
			if len(res) < 10 {
				res = append(res, clean(who, 32))
			}
		}
	}
	return res
}

// guardedUIDs: the app users whose answers to other hosts tando's nftables rules drop
// (firewall.nft: "meta skuid <uid> ct direction reply drop").
func (h *Host) guardedUIDs() map[int]bool {
	m := map[int]bool{}
	for _, l := range lines(readFile(filepath.Join(h.Env.Root, "firewall.nft"), 4<<20), 50000) {
		if !strings.Contains(l, "ct direction reply drop") {
			continue
		}
		f := strings.Fields(l)
		for i := 0; i+1 < len(f); i++ {
			if f[i] == "skuid" {
				if n, ok := decimal.Parse(f[i+1], 10); ok {
					m[int(n)] = true
				}
			}
		}
	}
	return m
}

// zombies counts processes in state Z.
func (h *Host) zombies() int {
	ents, err := os.ReadDir(h.Env.Proc)
	if err != nil {
		return 0
	}
	n := 0
	for i, e := range ents {
		if i > 20000 {
			break
		}
		if _, err := strconv.Atoi(e.Name()); err != nil {
			continue
		}
		b := readFile(filepath.Join(h.Env.Proc, e.Name(), "stat"), 1024)
		if j := strings.LastIndexByte(string(b), ')'); j >= 0 && j+2 < len(b) && b[j+2] == 'Z' {
			n++
		}
	}
	return n
}

// watchSetting reads one numeric setting of tando-watch's alerts.conf (the backup check's age).
func watchSetting(b []byte, key string, def int64) int64 {
	for _, l := range lines(b, 5000) {
		if v, ok := strings.CutPrefix(l, key+"="); ok {
			if n, ok := decimal.Parse(v, 9); ok {
				return n
			}
		}
	}
	return def
}

// backups: the apps with daily backups and their last one (the state tando-watch's backup check
// reads: last_backup, else counted from the app's creation).
func (h *Host) backups() []AppBackup {
	ents, _ := os.ReadDir(filepath.Join(h.Env.Root, "apps"))
	var res []AppBackup
	for _, e := range ents {
		a := e.Name()
		if !valid.App(a) {
			continue
		}
		d := filepath.Join(h.Env.Root, "apps", a)
		conf, err := kvfile.Parse(strings.NewReader(string(readFile(filepath.Join(d, "app.conf"), 1<<20))))
		if err != nil || conf["backup"] != "daily" {
			continue
		}
		st, _ := kvfile.Parse(strings.NewReader(string(readFile(filepath.Join(d, "state"), 1<<20))))
		b := AppBackup{App: a}
		if n, ok := decimal.Parse(st["last_backup"], 12); ok {
			b.Last, b.Since = n, n
		} else {
			b.Since = mtime(filepath.Join(d, "app.conf"))
		}
		res = append(res, b)
	}
	return res
}

// dirBytes is the size of the files under dir, depth levels down (the journal: machine-id/*).
func dirBytes(dir string, depth int) int64 {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return 0
	}
	var n int64
	for i, e := range ents {
		if i > 5000 {
			break
		}
		if e.IsDir() && depth > 1 {
			n += dirBytes(filepath.Join(dir, e.Name()), depth-1)
		} else if fi, err := e.Info(); err == nil && fi.Mode().IsRegular() {
			n += fi.Size()
		}
	}
	return n
}

// caddyOurs is the agent's caddy_ours: host setup installed this Caddy (host.conf
// caddy_installed=yes), or its Caddyfile has no site block but ":80" (tando's sites are imported).
// Only then does tando change what applies to every site of it, and only then may it reboot the
// server on its own.
func (h *Host) caddyOurs() bool {
	hc, _ := kvfile.Parse(strings.NewReader(string(readFile(filepath.Join(h.Env.Root, "host.conf"), 1<<20))))
	if hc["caddy_installed"] == "yes" {
		return true
	}
	cf := readFile(h.p("/etc/caddy/Caddyfile"), 4<<20)
	if cf == nil {
		return true // no Caddy, no other sites
	}
	return !otherSites(cf)
}

// otherSites: a line that opens a site block other than the global options or ":80" (the awk of
// caddy_ours: /^[^[:space:]#]/ && /\{[[:space:]]*$/ && !/^\{/ && !/^:80[[:space:]]*\{/).
func otherSites(cf []byte) bool {
	for _, l := range lines(cf, 100000) {
		if l == "" || l[0] == ' ' || l[0] == '\t' || l[0] == '#' || l[0] == '{' {
			continue
		}
		t := strings.TrimRight(l, " \t")
		if !strings.HasSuffix(t, "{") {
			continue
		}
		if s := strings.TrimSpace(strings.TrimSuffix(t, "{")); s == ":80" {
			continue
		}
		return true
	}
	return false
}

// secretModes: tando files that hold secrets and must be root's alone (or the app's group's):
// the probe secret, the notifier secrets, the apps' env files.
func (h *Host) secretModes() []string {
	var bad []string
	check := func(p string, maxPerm os.FileMode) {
		fi, err := os.Lstat(p)
		if err != nil {
			return
		}
		if fi.Mode().Perm()&^maxPerm != 0 && len(bad) < 20 {
			bad = append(bad, p+" "+strconv.FormatUint(uint64(fi.Mode().Perm()), 8))
		}
	}
	check(filepath.Join(h.Env.Root, "probe.header"), 0o600)
	check(filepath.Join(h.Env.Root, "alerts.d"), 0o700)
	if ents, err := os.ReadDir(filepath.Join(h.Env.Root, "alerts.d")); err == nil {
		for _, e := range ents {
			check(filepath.Join(h.Env.Root, "alerts.d", e.Name()), 0o600)
		}
	}
	apps, _ := os.ReadDir(filepath.Join(h.Env.Root, "apps"))
	for _, a := range apps {
		if valid.App(a.Name()) {
			check(filepath.Join(h.Env.Root, "apps", a.Name(), "env"), 0o640)
		}
	}
	sort.Strings(bad)
	return bad
}
