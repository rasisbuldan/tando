package metrics

import (
	"path/filepath"
	"strconv"
	"strings"

	"tando/srv/internal/cgroup"
	"tando/srv/internal/decimal"
)

// tandod.x: what the monitoring itself costs, a minute at a time (docs/MONITORING.md, "What the
// monitoring costs"): tandod's cgroup (its CPU with the programs it ran, its anon memory, its page
// cache, major faults and refaults) and two counters only tandod has (SelfCounters): the
// programs it started and the requests readers sent to its socket (the dashboard, tando status,
// top: shown apart, as they are the readers' cost, not the monitor's). Written by every sample;
// a sample that is not tandod's (the timer's fallback) writes "-" for the two counters.

// selfXCols are tandod.x's columns after the time.
var selfXCols = []col{
	{"cpu_ms", 'a', 1}, {"anon_bytes", 'a', 1}, {"file_bytes", 'a', 1},
	{"major_faults", 's', 1}, {"refaults", 's', 1}, {"children", 's', 1}, {"requests", 's', 1},
}

// SelfCounters are tandod's own counters: its pid, the programs it has started and the socket
// requests it has answered since it started (set by the daemon; nil in a one-shot).
type SelfCounters func() (pid, children, requests int64)

// selfStatKeys: what readSelfRaw takes of memory.stat (kernels before 5.9 have one
// workingset_refault; later ones split it into _anon and _file, and the page cache's is _file).
var selfStatKeys = map[string]string{"anon": "s_anon", "file": "s_file", "pgmajfault": "s_majflt",
	"workingset_refault_file": "s_refault", "workingset_refault": "s_refault"}

// selfCgroup is tandod.service's cgroup directory.
func (m Metrics) selfCgroup() string {
	return filepath.Join(m.Env.Cgroup, "system.slice", "tandod.service")
}

// readSelfRaw adds tandod's counters ("s_" keys) to r; none when its cgroup has no cpu.stat (it
// is not installed, or not running).
func (m Metrics) readSelfRaw(r raw) {
	dir := m.selfCgroup()
	usec, ok := cgroup.Value(filepath.Join(dir, "cpu.stat"), "usage_usec")
	if !ok {
		return
	}
	r["s_usec"] = usec
	keyed(filepath.Join(dir, "memory.stat"), func(k, v string) {
		if n, ok := selfStatKeys[k]; ok {
			if x, err := strconv.ParseInt(v, 10, 64); err == nil {
				r[n] = x
			}
		}
	})
	if m.Self != nil {
		pid, ch, rq := m.Self()
		r["s_pid"], r["s_children"], r["s_requests"] = pid, ch, rq
	}
}

func (d deltas) selfLine(c raw) string {
	cpu := "-"
	if u, ok := d.diff("s_usec"); ok {
		cpu = decimal.Itoa(u * 60 / d.dt / 1000)
	}
	counters := func(k string) string {
		pp, ok1 := d.prev["s_pid"]
		cp, ok2 := c["s_pid"]
		if !ok1 || !ok2 || pp != cp {
			return "-" // another tandod (or none): its counters began again
		}
		return d.rate(k)
	}
	return strings.Join([]string{cpu, c.gauge("s_anon"), c.gauge("s_file"), d.rate("s_majflt"), d.rate("s_refault"),
		counters("s_children"), counters("s_requests")}, "\t")
}
