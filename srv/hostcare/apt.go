package hostcare

import (
	"context"
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

	"tando/srv/internal/atomicfile"
	"tando/srv/internal/run"
)

// AptFacts are the slow facts: what apt would upgrade, dpkg's state, unattended-upgrades' and
// needrestart's view. Collected at most every apt_hours (and after dpkg changed), kept in
// /var/lib/tando/hostcare/apt.json (root 600).
type AptFacts struct {
	At          int64
	Err         string
	Pkgs        []Pkg
	ListsAt     int64 // when the package lists were last refreshed
	Held        []string
	Broken      []string // dpkg: installed but not configured
	Audit       []string // dpkg --audit
	UUInstalled bool
	UU          UUConfig
	UULog       UULog
	NR          Needrestart
	NRInstalled bool
	Kernels     []string
	History     []Upgrade // the newest apt runs that changed packages (at most 5)
	WWCount     int       // world-writable files under /opt/tando
	WW          []string  // the first few
	DpkgAt      int64     // dpkg's status file's mtime when collected
}

// Security is the pending security updates.
func (a AptFacts) Security() []Pkg {
	var res []Pkg
	for _, p := range a.Pkgs {
		if p.Security {
			res = append(res, p)
		}
	}
	return res
}

// aptFacts returns the cache, refreshed first when it is older than apt_hours, dpkg's state
// changed since (an upgrade ran), or force (as root only: apt-get -s and needrestart are run).
func (h *Host) aptFacts(ctx context.Context, s Settings, force bool) AptFacts {
	var a AptFacts
	if b := readFile(h.aptPath(), 16<<20); b != nil {
		json.Unmarshal(b, &a)
	}
	dpkgAt := mtime(h.p("/var/lib/dpkg/status"))
	stale := a.At == 0 || h.now()-a.At >= s.Num("apt_hours")*3600 || dpkgAt != a.DpkgAt || a.At > h.now()
	if h.Env.EUID != 0 || !(force || stale) {
		return a
	}
	a = h.collectApt(ctx)
	a.DpkgAt = dpkgAt
	if b, err := json.Marshal(a); err == nil && h.mkdir() == nil {
		atomicfile.Write(h.aptPath(), b, atomicfile.Mode(0o600))
	}
	return a
}

func (h *Host) collectApt(ctx context.Context) AptFacts {
	a := AptFacts{At: h.now()}
	if _, err := os.Stat(h.p("/usr/bin/apt-get")); err != nil {
		a.Err = "no apt on this server"
		return a
	}
	b, err := h.Env.Run.Output(ctx, run.Cmd{Argv: []string{"apt-get", "-s", "-o", "Debug::NoLocking=1", "dist-upgrade"}, Timeout: 3 * time.Minute})
	if err != nil {
		a.Err = clean("apt-get -s dist-upgrade failed: "+err.Error(), 200)
	}
	for _, p := range ParseAptSim(b) {
		p.Name, p.Old, p.New = clean(p.Name, 80), clean(p.Old, 60), clean(p.New, 60)
		for i := range p.Origins {
			p.Origins[i] = clean(p.Origins[i], 80)
		}
		if len(a.Pkgs) < 2000 {
			a.Pkgs = append(a.Pkgs, p)
		}
	}
	a.ListsAt = listsAt(h.p("/var/lib/apt/lists"), h.p("/var/lib/apt/periodic/update-success-stamp"))
	d := ParseDpkgStatus(readFile(h.p("/var/lib/dpkg/status"), 32<<20), "unattended-upgrades", "needrestart")
	for _, x := range d.Held {
		a.Held = append(a.Held, clean(x, 80))
	}
	for _, x := range d.Broken {
		a.Broken = append(a.Broken, clean(x, 100))
	}
	for _, k := range d.Kernels {
		a.Kernels = append(a.Kernels, clean(k, 64))
	}
	_, a.UUInstalled = d.Installed["unattended-upgrades"]
	_, a.NRInstalled = d.Installed["needrestart"]
	if b, err := h.Env.Run.Output(ctx, run.Cmd{Argv: []string{"dpkg", "--audit"}, Timeout: time.Minute}); err == nil {
		for _, x := range ParseDpkgAudit(b) {
			a.Audit = append(a.Audit, clean(x, 80))
		}
	}
	if b, err := h.Env.Run.Output(ctx, run.Cmd{Argv: []string{"apt-config", "dump"}, Timeout: time.Minute}); err == nil {
		a.UU = ParseAptConfig(b)
	}
	a.UULog = ParseUULog(readTail(h.p("/var/log/unattended-upgrades/unattended-upgrades.log"), 512<<10), h.Loc)
	a.UULog.Err = clean(a.UULog.Err, 200)
	if a.NRInstalled {
		// -b batch output, -r l: list only (never restarts anything)
		if b, err := h.Env.Run.Output(ctx, run.Cmd{Argv: []string{"needrestart", "-b", "-r", "l"}, Timeout: 2 * time.Minute}); err == nil {
			a.NR = ParseNeedrestart(b)
			for i := range a.NR.Services {
				a.NR.Services[i] = clean(a.NR.Services[i], 100)
			}
			a.NR.KernelCurrent, a.NR.KernelExpected = clean(a.NR.KernelCurrent, 64), clean(a.NR.KernelExpected, 64)
		}
	}
	hist := ParseAptHistory(readTail(h.p("/var/log/apt/history.log"), 512<<10), h.Loc)
	if len(hist) > 5 {
		hist = hist[len(hist)-5:]
	}
	for _, u := range hist {
		u.By = clean(u.By, 40)
		for i := range u.Pkgs {
			u.Pkgs[i] = clean(u.Pkgs[i], 80)
		}
		a.History = append(a.History, u)
	}
	a.WWCount, a.WW = worldWritable(h.Env.Root, 300000)
	return a
}

// listsAt: when apt last refreshed its package lists (the newest Release file, or the stamp
// APT::Periodic writes after a successful update).
func listsAt(dir, stamp string) int64 {
	t := mtime(stamp)
	ents, _ := os.ReadDir(dir)
	for _, e := range ents {
		n := e.Name()
		if !strings.HasSuffix(n, "Release") {
			continue
		}
		if fi, err := e.Info(); err == nil && fi.ModTime().Unix() > t {
			t = fi.ModTime().Unix()
		}
	}
	return t
}

// worldWritable walks root (not following links, not leaving its file system) and counts files
// and directories any user may write, at most max entries looked at; the first 5 are named.
func worldWritable(root string, max int) (int, []string) {
	n, seen := 0, 0
	var first []string
	var dev uint64
	if st, err := os.Stat(root); err == nil {
		dev = devOf(st)
	}
	filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		seen++
		if seen > max {
			return filepath.SkipAll
		}
		if d.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		fi, err := d.Info()
		if err != nil {
			return nil
		}
		if d.IsDir() && dev != 0 && devOf(fi) != dev {
			return filepath.SkipDir
		}
		// a sticky world-writable directory (a /tmp) still lets anyone add files: counted too
		if fi.Mode().Perm()&0o002 != 0 {
			n++
			if len(first) < 5 {
				first = append(first, clean(p, 120))
			}
		}
		return nil
	})
	return n, first
}
