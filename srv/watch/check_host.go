package watch

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"tando/srv/internal/decimal"
	"tando/srv/internal/fsinfo"
	"tando/srv/internal/run"
)

// checkHostDisk: space and inodes of the file systems tando writes to (/, /var, /opt/tando), the
// fullest one named. statfs(2), as df would read them, without a fork.
func checkHostDisk(t *tick) {
	mounts := t.w.mounts()
	seen := map[string]bool{}
	var worst, wi int64
	var worstp, wip string
	for _, p := range t.w.Disks {
		u, ok := t.w.df(p, mounts)
		if !ok || seen[u.target] {
			continue
		}
		seen[u.target] = true
		if decimal.IsDigits(u.pct) && num(u.pct, 0) > worst {
			worst, worstp = num(u.pct, 0), u.target
		}
		if decimal.IsDigits(u.ipct) && num(u.ipct, 0) > wi {
			wi, wip = num(u.ipct, 0), u.target
		}
	}
	if t.cfg.on("disk", "") {
		if worst >= t.cfg.num("disk_pct", "") {
			t.sample("_host.disk", "_host", "disk", bad, "disk "+worstp+" is "+decimal.Itoa(worst)+"% full", 1)
		} else {
			t.sample("_host.disk", "_host", "disk", ok, "", 1)
		}
	}
	if t.cfg.on("inodes", "") {
		if wi >= t.cfg.num("inode_pct", "") {
			t.sample("_host.inodes", "_host", "inodes", bad, wip+" uses "+decimal.Itoa(wi)+"% of its inodes", 1)
		} else {
			t.sample("_host.inodes", "_host", "inodes", ok, "", 1)
		}
	}
}

// checkHostMemory: MemAvailable and memory pressure, swap, and the 5-minute load. Not while every
// app is held: memory and load settle after a restart.
func checkHostMemory(t *tick) {
	if t.holdAll {
		return
	}
	mt, ma, st, sf := t.w.meminfo()
	psi := t.w.psi()
	hf, mp, pp := t.cfg.num("host_for", ""), t.cfg.num("mem_avail_pct", ""), t.cfg.num("psi_pct", "")
	if t.cfg.on("host_memory", "") {
		switch {
		case mt > 0 && ma*100 < mt*mp:
			t.sample("_host.memory", "_host", "memory", bad, "only "+decimal.Itoa(ma>>10)+" MB of "+decimal.Itoa(mt>>10)+" MB RAM available", hf)
		case decimal.IsDigits(psi) && num(psi, 0) >= pp:
			t.sample("_host.memory", "_host", "memory", bad, "memory pressure: tasks stalled "+psi+"% of the last minute", hf)
		default:
			t.sample("_host.memory", "_host", "memory", ok, "", hf)
		}
	}
	if t.cfg.on("swap", "") && st > 0 {
		if (st-sf)*100 >= st*t.cfg.num("swap_pct", "") {
			t.sample("_host.swap", "_host", "swap", bad, "swap "+decimal.Itoa((st-sf)>>10)+" MB of "+decimal.Itoa(st>>10)+" MB used", hf)
		} else {
			t.sample("_host.swap", "_host", "swap", ok, "", hf)
		}
	}
	if t.cfg.on("load", "") {
		la := t.w.load5()
		c := t.w.ncpu()
		pct, n := t.cfg.num("load_pct", ""), t.cfg.num("load_for", "")
		// the load average with two decimals as an integer x100
		i, f, _ := strings.Cut(la, ".")
		v := num(i, 0)*100 + num(cut(f, 2), 0)
		if v >= c*pct {
			t.sample("_host.load", "_host", "load", bad, "load "+la+" (5 min) on "+decimal.Itoa(c)+" CPU", n)
		} else {
			t.sample("_host.load", "_host", "load", ok, "", n)
		}
	}
}

// checkFirewall: `nft flush ruleset` (the stock /etc/nftables.conf, firewall tools) drops
// tando's per-app loopback rules with everything else, silently. Loaded rules that differ from
// the file are loaded again (under fw_sync's lock), with an alert and an audit line.
func checkFirewall(t *tick) {
	root := t.w.Env.Root
	file, lockf := filepath.Join(root, "firewall.nft"), filepath.Join(root, ".fw.lock")
	fi, err := os.Stat(file)
	nft := which("nft")
	if !t.cfg.on("firewall", "") || err != nil || fi.Size() == 0 || !fsinfo.RegularFollow(lockf) || nft == "" {
		return
	}
	count := func() (want, got int) {
		b, _ := os.ReadFile(file)
		out, _ := t.w.Env.Run.Output(t.ctx, run.Cmd{Argv: []string{nft, "list", "table", "inet", "tando"}, Env: cmdEnv, Timeout: 20 * time.Second})
		return countLines(b, "meta skuid"), countLines(out, "meta skuid")
	}
	// the rules were complete at this ruleset generation: nothing changed since, nothing to list
	// (and firewall.nft not written since: its time and size are part of the mark)
	gen, gerr := nftGen()
	mark := decimal.Itoa(int64(gen)) + "," + decimal.Itoa(fi.ModTime().UnixNano()) + "," + decimal.Itoa(fi.Size())
	if gerr == nil && t.vs.get("fwgen") == mark {
		t.sample("_host.firewall", "_host", "firewall", ok, "", 1)
		return
	}
	det := ""
	if want, got := count(); want != got {
		if f, ok := flockWait(lockf, 30*time.Second); ok {
			if want, got = count(); want != got {
				if _, err := t.w.Env.Run.Output(t.ctx, run.Cmd{Argv: []string{nft, "-f", file}, Env: cmdEnv, Timeout: 30 * time.Second}); err == nil {
					det = "the per-app loopback rules were gone (" + decimal.Itoa(int64(got)) + " of " + decimal.Itoa(int64(want)) + " loaded; nft flush ruleset?): loaded again"
				} else {
					det = "the per-app loopback rules are gone (" + decimal.Itoa(int64(got)) + " of " + decimal.Itoa(int64(want)) + " loaded) and could not be loaded again"
				}
			}
			f.Close()
		}
	}
	if det == "" {
		if gerr == nil {
			if g, err := nftGen(); err == nil && g == gen { // (unchanged while it was listed)
				t.vs.set("fwgen", mark)
			}
		}
		t.sample("_host.firewall", "_host", "firewall", ok, "", 1)
		return
	}
	t.vs.del("fwgen")
	t.sample("_host.firewall", "_host", "firewall", bad, det, 1)
	if logs := t.w.bin("tando-logs"); isExec(logs) {
		t.w.Env.Run.Output(t.ctx, run.Cmd{Argv: []string{logs, "audit-write", "fw-restore", "-", "1", det}, Env: cmdEnv, Timeout: 20 * time.Second})
	}
}

// flockWait takes an exclusive flock on an existing file opened for reading (the agent's lock
// files, which tando-watch must not create or change), waiting up to timeout.
func flockWait(path string, timeout time.Duration) (*os.File, bool) {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, false
	}
	deadline := time.Now().Add(timeout)
	for {
		err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return f, true
		}
		if time.Now().After(deadline) {
			f.Close()
			return nil, false
		}
		time.Sleep(50 * time.Millisecond)
	}
}
