package watch

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"tando/srv/internal/decimal"
)

// checkMonitorCost: the monitoring itself costs more CPU than it should. It reads tandod.x, the
// per-minute cost srv/metrics writes (tandod's cgroup CPU with the programs it started, and the
// readers' requests apart), and judges only minutes without a reader's request: what a dashboard
// or `tando status` asks of tandod is the reader's cost, not the monitor's.
//
// It stays silent until there are monitor_cost_days (7) of data: then its normal is the median
// of those minutes (worked out again once a day, from the newest 7 days), and it fires when the
// average of the last hour's minutes is over monitor_cost_x (2) times that normal, and never
// over monitor_cost_cap_ms (600 ms a minute: 1% of one core). Fewer than 10 such minutes in the
// last hour: not judged (the state stays as it is).
func checkMonitorCost(t *tick) {
	if !t.cfg.on("monitor_cost", "") {
		return
	}
	file := filepath.Join(t.w.Env.Lib, "metrics", "tandod.x")
	base := strings.Fields(t.st.get("_host.monitor_cost.base")) // "<worked out at> <normal ms> <data since>"
	var at, normal, since int64 = -1, -1, -1
	if len(base) == 3 {
		at, normal, since = num(base[0], -1), num(base[1], -1), num(base[2], -1)
	}
	if at < 0 || t.now-at >= 86400 || t.now < at {
		old, _ := os.ReadFile(file + ".1")
		cur, _ := os.ReadFile(file)
		first, med := costMedian(append(old, cur...))
		if first > 0 && (since < 0 || first < since) {
			since = first
		}
		at, normal = t.now, med
		t.st.set("_host.monitor_cost.base", decimal.Itoa(at)+" "+decimal.Itoa(normal)+" "+decimal.Itoa(since))
	}
	if since < 0 || normal < 0 || t.now-since < t.cfg.num("monitor_cost_days", "")*86400 {
		t.sample("_host.monitor_cost", "_host", "monitor_cost", ok, "", 1)
		return
	}
	avg, n, reqs := costLastHour(file, t.now)
	if n < 10 {
		return
	}
	limit := min(normal*t.cfg.num("monitor_cost_x", ""), t.cfg.num("monitor_cost_cap_ms", ""))
	if avg <= limit {
		t.sample("_host.monitor_cost", "_host", "monitor_cost", ok, "", 1)
		return
	}
	t.sample("_host.monitor_cost", "_host", "monitor_cost", bad, "the monitoring (tandod and the programs it starts) used "+decimal.Itoa(avg)+
		" ms of CPU a minute over the last hour, over its limit of "+decimal.Itoa(limit)+" ms (its normal: "+decimal.Itoa(normal)+
		" ms; readers asked "+decimal.Itoa(reqs)+" times in the hour, not counted): tando top, journalctl -u tandod", 1)
}

// costMinute is one line of tandod.x: time, cpu ms, requests ("-": not known, -1).
func costMinute(line string) (t, cpu, req int64, ok bool) {
	f := strings.Split(line, "\t")
	if len(f) < 8 {
		return 0, 0, 0, false
	}
	t, cpu, req = num(f[0], -1), num(f[1], -1), num(f[7], -1)
	return t, cpu, req, t > 0 && cpu >= 0
}

// costMedian: the time of the first line, and the median cpu ms of the minutes nobody read
// (-1: none).
func costMedian(b []byte) (first, median int64) {
	first, median = -1, -1
	var v []int64
	for _, l := range strings.Split(string(b), "\n") {
		t, cpu, req, ok := costMinute(l)
		if t > 0 && first < 0 {
			first = t
		}
		if ok && req == 0 {
			v = append(v, cpu)
		}
	}
	if len(v) > 0 {
		slices.Sort(v)
		median = v[len(v)/2]
	}
	return first, median
}

// costLastHour: the average cpu ms of the last hour's minutes nobody read, how many there were,
// and the requests of the others (only the end of the file is read).
func costLastHour(file string, now int64) (avg, n, reqs int64) {
	f, err := os.Open(file)
	if err != nil {
		return 0, 0, 0
	}
	defer f.Close()
	const tailBytes = 64 << 10 // an hour of lines is about 3 KB
	if fi, err := f.Stat(); err == nil && fi.Size() > tailBytes {
		f.Seek(fi.Size()-tailBytes, io.SeekStart)
	}
	b, _ := io.ReadAll(io.LimitReader(f, tailBytes))
	if i := bytes.IndexByte(b, '\n'); i >= 0 && len(b) == tailBytes {
		b = b[i+1:] // (a line cut by the seek)
	}
	var sum int64
	for _, l := range strings.Split(string(b), "\n") {
		t, cpu, req, ok := costMinute(l)
		if !ok || t <= now-3600 || t > now {
			continue
		}
		if req > 0 {
			reqs += req
			continue
		}
		if req == 0 {
			sum, n = sum+cpu, n+1
		}
	}
	if n > 0 {
		avg = sum / n
	}
	return avg, n, reqs
}
