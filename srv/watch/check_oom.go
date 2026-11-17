package watch

import (
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"tando/srv/internal/decimal"
	"tando/srv/internal/run"
)

var oomUnitRe = regexp.MustCompile(`^([^ :]*): The kernel OOM killer`)

// checkOOMSlices notices OOM kills. Per-app counters are lost when the unit restarts (new
// cgroup), so a rise of the slice counters is attributed through the journal (only then: it
// costs a fork). Apps run under tando.slice since the per-app slices; older ones under
// system.slice. A kill outside the apps' units is the host's (Caddy, PostgreSQL, a job, ssh).
func checkOOMSlices(t *tick) {
	cg := t.w.Env.Cgroup
	s := evcount(filepath.Join(cg, "system.slice", "memory.events"), "oom_kill")
	u := evcount(filepath.Join(cg, "user.slice", "memory.events"), "oom_kill")
	r := evcount(filepath.Join(cg, "tando.slice", "memory.events"), "oom_kill")
	sl := decimal.Itoa(s) + ":" + decimal.Itoa(u) + ":" + decimal.Itoa(r)
	old := t.st.get("_oomc")
	o := strings.SplitN(old, ":", 3)
	for len(o) < 3 {
		o = append(o, "")
	}
	if old != "" && old != sl && (s > num(o[0], 0) || u > num(o[1], 0) || r > num(o[2], r)) {
		since := t.vs.n("last", t.now-120) - 5
		out, _ := t.w.Env.Run.Output(t.ctx, run.Cmd{
			Argv: []string{"journalctl", "--since", "@" + decimal.Itoa(since), "-o", "cat", "--no-pager", "-g", "OOM killer killed"},
			Env:  cmdEnv, Timeout: 20 * time.Second,
		})
		for _, l := range strings.Split(string(out), "\n") {
			if m := oomUnitRe.FindStringSubmatch(l); m != nil {
				t.oomUnits[m[1]] = true
			}
		}
		var hostUnits []string
		for un := range t.oomUnits {
			if !t.appUnits[un] {
				hostUnits = append(hostUnits, un)
			}
		}
		sort.Strings(hostUnits)
		hu := strings.Join(hostUnits, ", ")
		if len(t.oomUnits) == 0 {
			hu = "a process outside tando apps"
		}
		if hu != "" {
			t.st.set("_host.oom_t", decimal.Itoa(t.now))
			t.st.set("_host.oom_d", "OOM killer: "+hu)
		}
	}
	if old != sl {
		t.st.set("_oomc", sl)
	}
}

// checkOOM: the kernel's OOM killer killed a process of the app. A kill that systemd recovered
// from at once still fires: it lost requests. Resolves oom_quiet minutes after the last kill.
func checkOOM(t *tick, a *appTick) {
	if !a.hasUnit || !t.cfg.on("oom", a.name) {
		return
	}
	k := a.key("oom")
	n := evcount(filepath.Join(t.w.appCgroup(a.name), "memory.events"), "oom_kill")
	n0 := t.vs.n("oomk."+a.name, n)
	if n > n0 || t.oomUnits["tando-"+a.name+".service"] {
		t.st.set(a.name+".oom_t", decimal.Itoa(t.now))
	}
	t.vs.set("oomk."+a.name, decimal.Itoa(n))
	q := t.cfg.num("oom_quiet", a.name)
	if t.st.get(a.name+".oom_t") != "" && t.now-t.st.n(a.name+".oom_t", 0) < q*60 {
		t.sample(k, a.name, "oom", bad, "the kernel OOM killer killed the app (memory cap "+or(a.conf["memory"], "?")+")", 1)
	} else {
		t.sample(k, a.name, "oom", ok, "", 1)
		t.st.del(a.name + ".oom_t")
	}
}

// checkHostOOM: an OOM kill outside the apps, the same way.
func checkHostOOM(t *tick) {
	if !t.cfg.on("host_oom", "") {
		t.st.del("_host.oom_t")
	}
	if t.st.get("_host.oom_t") != "" {
		if t.now-t.st.n("_host.oom_t", 0) < t.cfg.num("oom_quiet", "")*60 {
			t.sample("_host.oom", "_host", "oom", bad, t.st.or("_host.oom_d", "OOM kill"), 1)
		} else {
			t.sample("_host.oom", "_host", "oom", ok, "", 1)
			t.st.del("_host.oom_t", "_host.oom_d")
		}
	}
	if t.st.get("_host.oom.st") != "" && t.st.get("_host.oom_t") == "" {
		t.sample("_host.oom", "_host", "oom", ok, "", 1)
	}
}

// or is s, or def when s is empty (bash ${s:-def}).
func or(s, def string) string {
	if s == "" {
		return def
	}
	return s
}
