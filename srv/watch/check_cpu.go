package watch

import (
	"os"
	"path/filepath"
	"strings"

	"tando/srv/internal/cgroup"
	"tando/srv/internal/decimal"
)

// busyKinds are the units of an app that run its build, release command, pre-flight, a shell or a
// backup (tando-<app>-<kind>...): high CPU while one of them runs is expected, not judged.
var busyKinds = []string{"act", "pre", "rel", "venv", "shell", "envcheck", "backup", "build"}

// checkCPU: cpu_sustained. The CPU of the app's whole slice (web process, workers, jobs) above
// cpu_pct % of its CPU limit (of one core when it has none) for cpu_for samples in a row: a
// process that never rests, as a miner does. Not judged during an activation and deploy_grace
// after it (checkStuck holds the app), nor while a build, release command, pre-flight, shell or
// backup of the app runs; such a minute does not count either way. The slice is read even when
// the web process is idle: a worker or a job of an idle app counts. Runs before checkDown (an
// idle or stopped web process holds the app for the checks after it).
func checkCPU(t *tick, a *appTick) {
	if !t.cfg.on("cpu_sustained", a.name) || t.holdAll {
		return
	}
	sl := filepath.Dir(t.w.appCgroup(a.name))
	if filepath.Base(sl) == "system.slice" { // an app from before the per-app slices
		return
	}
	usec, okU := cgroup.Value(filepath.Join(sl, "cpu.stat"), "usage_usec")
	vk := "cpu." + a.name
	prev := strings.Fields(t.vs.get(vk))
	if !okU {
		t.vs.del(vk)
		return
	}
	t.vs.set(vk, decimal.Itoa(usec)+" "+decimal.Itoa(t.now))
	if len(prev) != 2 || a.hold || busyPhase(sl, a.name) {
		return
	}
	pu, pt := num(prev[0], -1), num(prev[1], 0)
	dt := t.now - pt
	if pu < 0 || usec < pu || dt <= 0 || dt > 300 {
		return // the first sample, a slice that started again, or samples too far apart
	}
	// % of one core over the minute, then of the limit (cpu.max "quota period"; "max": none)
	pct := (usec - pu) * 100 / (dt * 1_000_000)
	lim := int64(100)
	if f := strings.Fields(readFirst(filepath.Join(sl, "cpu.max"))); len(f) == 2 && decimal.IsDigits(f[0]) && num(f[1], 0) > 0 {
		lim = num(f[0], 0) * 100 / num(f[1], 0)
	}
	if lim <= 0 {
		return
	}
	k := a.key("cpu_sustained")
	share := pct * 100 / lim
	need := t.cfg.num("cpu_for", a.name)
	if share < t.cfg.num("cpu_pct", a.name) {
		t.sample(k, a.name, "cpu_sustained", ok, "", need)
		return
	}
	t.sample(k, a.name, "cpu_sustained", bad, "CPU at "+decimal.Itoa(share)+"% of its limit ("+decimal.Itoa(pct)+
		"% of one core) for "+decimal.Itoa(need)+" minutes or more, with no deploy, build or backup running: a process "+
		"that never rests (a loop, or someone else's miner): tando top shows which unit", need)
}

// busyPhase: a unit of a busy kind of the app runs (its cgroup is in the app's slice).
func busyPhase(slice, app string) bool {
	es, _ := os.ReadDir(slice)
	for _, e := range es {
		rest, ok := strings.CutPrefix(e.Name(), "tando-"+app+"-")
		if !ok || !e.IsDir() {
			continue
		}
		for _, k := range busyKinds {
			if strings.HasPrefix(rest, k) {
				return true
			}
		}
	}
	return false
}
