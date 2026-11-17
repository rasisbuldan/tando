package watch

import (
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"tando/srv/internal/apps"
	"tando/srv/internal/bashread"
	"tando/srv/internal/decimal"
	"tando/srv/internal/fsinfo"
	"tando/srv/internal/out"
	"tando/srv/internal/valid"
)

// Health is the verb `health [app]`: uptime and incidents from the per-minute record, for tando
// health (root: the files are root's).
//
//	up <app> <uptime 24h x100|-> <uptime 7d x100|-> <minutes judged 24h> <7d> <incidents 7d>
//	   <p50 ms 24h> <p95 ms 24h> <avg probe ms per hour, 24 values oldest first> <last class> <last ms>
//	   <firing checks, comma-separated|->
//	inc <app> <start> <end|-> <check> <cause>      newest first (15 for one app, 3 for all)
//	tail <app> <time> <line>                       one app: the last lines before its last crash
//
// A minute counts as up when the probe passed (or the app has no probe and runs); hold (deploys,
// boot) and stopped minutes are not counted at all.
func (w Watch) Health(o *out.Writer, args []string) error {
	if err := needRoot(w.Env); err != nil {
		return err
	}
	now := w.now()
	st := newStore(loadQuiet(w.statePath()))
	var list []string
	one := len(args) > 0 && args[0] != ""
	if one {
		if !valid.App(args[0]) || !fsinfo.DirFollow(w.appDir(args[0])) {
			return errf("no such app: %s", args[0])
		}
		list = []string{args[0]}
	} else {
		list, _ = apps.Names(w.Env.Root)
	}
	for _, a := range list {
		var fir []string
		for _, c := range []string{"down", "health", "oom", "restarts", "http", "slow", "errors", "logs", "memory", "disk"} {
			if st.get(a+"."+c+".st") == "firing" {
				fir = append(fir, c)
			}
		}
		firs := or(strings.Join(fir, ","), "-")
		incf := filepath.Join(w.Dir, "incidents", a+".tsv")
		incs, _ := os.ReadFile(incf)
		var ninc int64
		for _, l := range bashread.Lines(incs) {
			p := strings.Split(l, "\t")
			if len(p) > 2 && awkNum(p[0]) >= float64(now-604800) && p[2] != "restart" {
				ninc++
			}
		}
		if b, err := os.ReadFile(filepath.Join(w.Dir, "probe", a)); err == nil {
			o.Row(uptimeRow(a, b, now, ninc, firs)...)
		} else {
			o.Row("up", a, "-", "-", "0", "0", decimal.Itoa(ninc), "-", "-", "-", "-", "-", firs)
		}
		n := int64(3)
		if one {
			n = 15
		}
		ls := tailLines(incf, n)
		for i := len(ls) - 1; i >= 0; i-- {
			f := bashread.Fields(ls[i], 4)
			o.Row("inc", a, f[0], f[1], f[2], f[3])
		}
		if one {
			for _, l := range tailLines(filepath.Join(w.Dir, "tail", a), 1<<30) {
				f := bashread.Fields(l, 2)
				o.Row("tail", a, f[0], f[1])
			}
		}
	}
	return nil
}

// awkNum is the numeric value awk gives a field: its leading number, 0 when there is none.
func awkNum(s string) float64 {
	s = strings.TrimLeft(s, " \t")
	end := 0
	for end < len(s) && (s[end] >= '0' && s[end] <= '9' || s[end] == '.' || (end == 0 && (s[end] == '-' || s[end] == '+'))) {
		end++
	}
	for end > 0 {
		if v, err := strconv.ParseFloat(s[:end], 64); err == nil {
			return v
		}
		end--
	}
	return 0
}

// uptimeRow computes the up row from the probe record ("time class [ms]" lines) as the shell's
// awk did: uptime over judged minutes, probe latency percentiles from a log histogram (5% wide
// buckets), and the average probe time of each of the last 24 hours.
func uptimeRow(a string, b []byte, now, ninc int64, fir string) []string {
	d1, d7 := float64(now-86400), float64(now-604800)
	lg := math.Log(1.05)
	var n1, n7, u1, u7, nb, mb int
	hist := map[int]int{}
	var hs [24]float64
	var hn [24]int
	last, lastms := "", ""
	for l := range strings.SplitSeq(string(b), "\n") {
		f := strings.Fields(l)
		if len(f) == 0 {
			continue // (awk sees an empty line as one whose $1 is 0: older than 7 days)
		}
		t := awkNum(f[0])
		if t < d7 {
			continue
		}
		c, msf := f[1:2], ""
		cls := ""
		if len(c) > 0 {
			cls = c[0]
		}
		if len(f) > 2 {
			msf = f[2]
		}
		ms := awkNum(msf)
		last, lastms = cls, msf
		if cls == "hold" || cls == "stopped" {
			continue
		}
		n7++
		if cls == "ok" {
			u7++
		}
		if t < d1 {
			continue
		}
		n1++
		if cls == "ok" {
			u1++
		}
		if msf == "" {
			continue
		}
		h := min(int((t-d1)/3600), 23)
		hs[h] += ms
		hn[h]++
		bk := 0
		if ms > 1 {
			bk = int(math.Log(ms)/lg) + 1
		}
		hist[bk]++
		nb++
		mb = max(mb, bk)
	}
	pct := func(p float64) string {
		if nb == 0 {
			return "-"
		}
		need, cum := p*float64(nb), 0
		for i := 0; i <= mb; i++ {
			cum += hist[i]
			if float64(cum) >= need {
				return decimal.Itoa(int64(math.Exp((float64(i)-0.5)*lg) + 0.5))
			}
		}
		return "-"
	}
	sp := make([]string, 24)
	for h := range 24 {
		sp[h] = "-"
		if hn[h] > 0 {
			sp[h] = decimal.Itoa(int64(hs[h]/float64(hn[h]) + 0.5))
		}
	}
	up := func(u, n int) string {
		if n == 0 {
			return "-"
		}
		return decimal.Itoa(int64(u) * 10000 / int64(n))
	}
	return []string{"up", a, up(u1, n1), up(u7, n7), decimal.Itoa(int64(n1)), decimal.Itoa(int64(n7)), decimal.Itoa(ninc), pct(0.5), pct(0.95),
		strings.Join(sp, ","), or(last, "-"), or(lastms, "-"), fir}
}
