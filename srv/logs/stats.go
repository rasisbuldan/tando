package logs

import (
	"context"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"

	"tando/srv/internal/atomicfile"
	"tando/srv/internal/fsinfo"
	"tando/srv/internal/out"
	"tando/srv/logs/lines"
)

// Log stats: per-app disk use, lines and bytes per hour over the last 24 hours. Counts are kept
// per hour in Cache/<app>.stats with the cursor of the last entry read; a refresh reads only the
// entries written since (at most statsMax), so the cost follows the log rate. The cache file:
//
//	cursor <cursor>
//	updated <epoch>
//	H <hour> <lines> <bytes>
//	S <hour> <lines journald dropped>
const (
	statsTTL = 60     // seconds a result is reused
	statsMax = 300000 // journal entries read per app per refresh at most
)

type hourly map[int64][3]int64 // hour -> lines, bytes, suppressed

// LogStats (log-stats [app]) prints one "logs" row per app.
func (l *Logs) LogStats(ctx context.Context, name string, w *out.Writer) error {
	if err := l.needRoot(); err != nil {
		return err
	}
	ensureDir(l.P.Cache, 0o700, -1, -1)
	if name != "" {
		a, err := l.app(name)
		if err != nil {
			return err
		}
		a.stats(ctx, w)
		return nil
	}
	for _, n := range l.appDirs() {
		a, err := l.app(n)
		if err != nil {
			l.warn("tando-logs: %v", err)
			continue
		}
		a.stats(ctx, w)
	}
	return nil
}

// appDirs: the apps with an app.conf (the shell's $R/apps/*/app.conf).
func (l *Logs) appDirs() []string {
	ents, _ := os.ReadDir(filepath.Join(l.Env.Root, "apps"))
	var n []string
	for _, e := range ents {
		if fi, err := os.Stat(filepath.Join(l.Env.Root, "apps", e.Name(), "app.conf")); err == nil && !fi.IsDir() {
			n = append(n, e.Name())
		}
	}
	return n
}

// short-unix: "<epoch.usec> <host> <ident>[pid]: <message>". JSON output would cost about 6x more
// CPU (2.2 s against 0.33 s for 100k entries, measured).
func countLine(b []byte, full int, h hourly) {
	var f [4][]byte
	nf := lines.Fields(b, f[:])
	ts := lines.Num(b)
	if ts >= 1e17 || ts <= -1e17 {
		return // not a time (a continuation line that starts with a long number)
	}
	hour := int64(ts/3600) * 3600
	if nf >= 3 && lines.HasPrefix(f[2], "systemd-journald") {
		if m := reSuppressed.FindSubmatch(b); m != nil {
			c := h[hour]
			c[2] += int64(lines.Num(m[1]))
			h[hour] = c
		}
		return
	}
	// the message's bytes: after "]: " (or ": " without a pid)
	p := lines.Index(b, "]: ")
	if p >= 0 {
		p++
	} else {
		p = lines.Index(b, ": ")
	}
	c := h[hour]
	c[0]++
	c[1] += int64(full - p - 2)
	h[hour] = c
}

var reSuppressed = regexp.MustCompile(`Suppressed ([0-9]+) messages`)

// stats is the app's logs row: journal and request log disk use, and lines, bytes and
// suppressed lines per hour over the last 24 h. The hourly counts are kept in Cache/<app>.stats
// (with the journal cursor they reach) and brought up to date at most every statsTTL.
func (a *app) stats(ctx context.Context, w *out.Writer) {
	f := filepath.Join(a.l.P.Cache, a.name+".stats")
	t := a.l.Env.Now().Unix()
	hour0 := t/3600*3600 - 23*3600
	cur, upd, h := readStats(f, hour0)
	if t-upd >= statsTTL && fsinfo.RegularFollow(a.nsConf()) {
		a.updateStats(ctx, f, cur, hour0, t, h)
		upd = t
	}
	jb := "-"
	if d := a.nsDir(); d != "" && fsinfo.DirFollow(d) {
		if n, err := diskUsage(d); err == nil {
			jb = strconv.FormatInt(n, 10)
		}
	}
	var ab int64
	if fsinfo.DirFollow(a.logDir()) {
		ab, _ = diskUsage(a.logDir())
	}
	var lines24, bytes24, sup int64
	var hl, hb []string
	for hr := hour0; hr <= hour0+23*3600; hr += 3600 {
		c := h[hr]
		lines24 += c[0]
		bytes24 += c[1]
		sup += c[2]
		hl = append(hl, strconv.FormatInt(c[0], 10))
		hb = append(hb, strconv.FormatInt(c[1], 10))
	}
	r := a.roll()
	// (then: retention in hours, the request log's budget, and where the journal cap comes from)
	w.Row("logs", a.name, jb, strconv.FormatInt(sizeBytes(a.setting("log_max")), 10), strconv.FormatInt(ab, 10),
		strconv.FormatInt(lines24, 10), strconv.FormatInt(bytes24, 10), strconv.FormatInt(sup, 10),
		strings.Join(hl, ","), strings.Join(hb, ","), strconv.FormatInt(t-upd, 10),
		strconv.FormatInt(keepHours(a.setting("log_keep")), 10), strconv.FormatInt(r.Max, 10), a.settingSrc("log_max"))
}

// readStats reads the stats cache: the journal cursor its counts reach, when they were updated,
// and the hours since hour0 ("H <hour> <lines> <bytes>", "S <hour> <suppressed>").
func readStats(f string, hour0 int64) (cur string, upd int64, h hourly) {
	h = hourly{}
	b, err := os.ReadFile(f)
	if err != nil {
		return "", 0, h
	}
	for line := range strings.SplitSeq(string(b), "\n") {
		k := strings.Fields(line)
		if len(k) < 2 {
			if len(k) == 1 && k[0] == "cursor" {
				cur = ""
			}
			continue
		}
		v := func(i int) int64 {
			if i >= len(k) {
				return 0
			}
			n, _ := strconv.ParseInt(k[i], 10, 64)
			return n
		}
		switch k[0] {
		case "cursor":
			cur = k[1]
		case "updated":
			upd = v(1)
		case "H":
			if v(1) >= hour0 {
				c := h[v(1)]
				c[0], c[1] = v(2), v(3)
				h[v(1)] = c
			}
		case "S":
			if v(1) >= hour0 {
				c := h[v(1)]
				c[2] = v(2)
				h[v(1)] = c
			}
		}
	}
	return cur, upd, h
}

// updateStats adds the journal lines after cur (since hour0 without a cursor, at most statsMax)
// to h and writes the cache f with the cursor they reach.
func (a *app) updateStats(ctx context.Context, f, cur string, hour0, t int64, h hourly) {
	jc := []string{"journalctl", "--no-pager", "-q", "-a", "-o", "short-unix", "--show-cursor", "--namespace=" + a.ns()}
	if cur != "" {
		jc = append(jc, "--after-cursor="+cur)
	} else {
		jc = append(jc, "--since=@"+strconv.FormatInt(hour0, 10))
	}
	jc = append(jc, "-n", strconv.Itoa(statsMax))
	fresh := hourly{}
	a.l.stream(ctx, jc, 2*time.Minute, 64<<10, func(ln lines.Line) bool {
		if lines.HasPrefix(ln.Text, "-- cursor: ") {
			cur = string(ln.Text[11:])
			return true
		}
		countLine(ln.Text, ln.Len, fresh)
		return true
	})
	for hr, c := range fresh {
		if hr >= hour0 {
			o := h[hr]
			h[hr] = [3]int64{o[0] + c[0], o[1] + c[1], o[2] + c[2]}
		}
	}
	var b strings.Builder
	b.WriteString("cursor " + cur + "\nupdated " + strconv.FormatInt(t, 10) + "\n")
	hours := make([]int64, 0, len(h))
	for hr := range h {
		hours = append(hours, hr)
	}
	slices.Sort(hours)
	for _, hr := range hours {
		if c := h[hr]; c[0] != 0 || c[1] != 0 {
			b.WriteString("H " + strconv.FormatInt(hr, 10) + " " + strconv.FormatInt(c[0], 10) + " " + strconv.FormatInt(c[1], 10) + "\n")
		}
	}
	for _, hr := range hours {
		if c := h[hr]; c[2] != 0 {
			b.WriteString("S " + strconv.FormatInt(hr, 10) + " " + strconv.FormatInt(c[2], 10) + "\n")
		}
	}
	atomicfile.Write(f, []byte(b.String()), atomicfile.Mode(0o644)) // (in a 700 directory)
}
