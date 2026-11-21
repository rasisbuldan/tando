package status

import (
	"bytes"
	"context"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"tando/srv/internal/bashread"
	"tando/srv/internal/cgroup"
	"tando/srv/internal/decimal"
	"tando/srv/internal/out"
	"tando/srv/internal/run"
	"tando/srv/internal/valid"
)

// sink collects a verb's output: rows through an out.Writer, and the other programs' output
// passed through as they printed it, in the order the shell printed them.
type sink struct {
	b bytes.Buffer
	w *out.Writer
}

func newSink() *sink { s := &sink{}; s.w = out.New(&s.b); return s }

func (s *sink) row(f ...string)    { s.w.Row(f...) }
func (s *sink) fields(f ...string) { s.w.Fields(f...) }
func (s *sink) kv(k, v string)     { s.w.KV(k, v) }

// relay adds the rows another tando program printed (cleaned by that program's out.Writer).
func (s *sink) relay(p []byte) { s.w.Relay(p) }

// to writes everything collected to w, in one write.
func (s *sink) to(w io.Writer) error {
	if err := s.w.Flush(); err != nil {
		return err
	}
	_, err := w.Write(s.b.Bytes())
	return err
}

// Status is the verb `status [app]`: a host row and one row per app; with an app also its log
// settings, releases, last 5 deploys, domains and the last 16 minutes of metrics; then the active
// alerts. Without an app the apps are those whose app.conf this caller may read.
func (c *Collector) Status(ctx context.Context, w io.Writer, name string) error {
	ctx = ctxOr(ctx)
	H := c.hostConf()
	type entry struct {
		name  string
		conf  kv
		state kv
	}
	var apps []entry
	var one *app
	if name != "" {
		a, err := c.selectApp(name)
		if err != nil {
			return err
		}
		one = a
		apps = append(apps, entry{a.name, a.conf, a.state})
	} else {
		for _, n := range c.readableApps() {
			d := c.appDir(n.name)
			apps = append(apps, entry{n.name, n.conf, loadKV(filepath.Join(d, "state"))})
		}
	}
	upt := c.uptime()
	s := newSink()
	s.row(HostRow(c.host(upt))...)
	if r := c.hostcareRow(); r != nil { // host care's counts (tando ls's hint), when root can read them
		s.row(r...)
	}
	if len(apps) == 0 {
		return s.to(w)
	}
	lg, lc := c.logStats(ctx, name)
	units := make([]string, len(apps))
	for i, a := range apps {
		units[i] = "tando-" + a.name + ".service"
	}
	shown, err := c.showUnits(ctx, units, unitProps)
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if err != nil {
		c.warn(err.Error())
		shown = nil
	}
	for i, a := range apps {
		f := AppFacts{Name: a.name, Conf: a.conf, State: a.state, Logs: lg[a.name],
			Mem:    memAnonShmem(filepath.Join(cgroup.AppDir(c.Env.Cgroup, a.name), "memory.stat")),
			CPUMin: c.cpuMinute(a.name)}
		if i < len(shown) {
			f.Unit = shown[i]
		}
		s.row(AppRow(f, H, upt)...)
		for _, r := range c.workerRows(ctx, a.name, a.conf, a.state) {
			s.row(r...)
		}
		if a.state.get("restore_cut") != "" { // a restore cut off while it replaced the data (the agent's restore_cut_row)
			s.row("restorecut", a.name, orV(a.state.get("restore_cut_id"), "-"), orV(a.state.get("restore_cut_safety"), "-"),
				orV(a.state.get("restore_cut_what"), "data"))
		}
	}
	if one != nil {
		if lc != nil {
			s.row(append([]string{"logcfg", name}, lc...)...)
		}
		for _, r := range ReleaseRows(one.state, c.releaseIDs(one.dir)) {
			s.row(r...)
		}
		c.history(s, name, 5)
		for _, x := range words(one.conf.get("domains")) {
			d := beforeLast(x, "|")
			s.row("domain", d, afterFirst(x, "|"), c.certExpiry(d))
		}
		// the last 16 minutes from tando-metrics (m rows: bucket, memory, cpu per mille, restarts, state)
		if executable(c.bin("tando-metrics")) {
			s.relay(c.trendOut(ctx, name))
		}
		// its offsite state: the file tando-offsite keeps (srv/offsite state.go), as one row
		if ob := loadKV(filepath.Join(c.Env.Lib, "offsite", "state", name)); ob.get("enabled") == "1" {
			s.row("offsite", or0(ob.get("last_upload")), or0(ob.get("pending")), or0(ob.get("oldest_pending")),
				orV(ob.get("alert_hours"), "6"), ob.get("creds"), ob.get("error"))
		}
	}
	if executable(c.bin("tando-watch")) { // active alerts
		s.relay(c.briefOut(ctx, name))
	}
	return s.to(w)
}

type confEntry struct {
	name string
	conf kv
}

// readableApps is `for a in "$R"/apps/*/app.conf; [[ -r $a ]]`: the apps whose app.conf this
// caller can read (root: all), with that app.conf, sorted by name (bash's glob order in the C and
// C.UTF-8 locales). Only valid app names: anything else under apps/ was not made by tando.
func (c *Collector) readableApps() []confEntry {
	ents, err := os.ReadDir(filepath.Join(c.Env.Root, "apps"))
	if err != nil {
		return nil
	}
	var res []confEntry
	for _, e := range ents {
		n := e.Name()
		if !valid.App(n) {
			continue
		}
		b, err := readBounded(filepath.Join(c.Env.Root, "apps", n, "app.conf"), maxKV, false)
		if err != nil {
			continue
		}
		res = append(res, confEntry{n, parseKV(b)})
	}
	sort.Slice(res, func(i, j int) bool { return res[i].name < res[j].name })
	return res
}

// logStats runs `tando-logs log-stats [app]` (root only, as the shell did) and returns per app
// the four words appended to its row, and for app the three words of its logcfg row:
//
//	while IFS=$'\t' read -r r a jb cap ab lines _ _ hl _ _ lk lr lsrc _; do
//	  LG[$a]="$((jb + ab)) ${cap:--} ${lines:--} ${hl:--}"
//	  [[ $a == "${1:-}" ]] && LC="${lk:--} ${lr:--} ${lsrc:--}"
//
// Both were expanded unquoted, so they are split into words here too.
func (c *Collector) logStats(ctx context.Context, name string) (map[string][]string, []string) {
	lg := map[string][]string{}
	var lc []string
	if c.Env.EUID != 0 || !executable(c.bin("tando-logs")) {
		return lg, nil
	}
	for _, l := range bashread.Lines(c.logStatsOut(ctx, name)) {
		f := bashread.Fields(l, 15)
		if f[0] != "logs" {
			continue
		}
		jb, ab := f[2], f[4]
		if !decimal.IsDigits(jb) {
			jb = "0"
		}
		if !decimal.IsDigits(ab) {
			ab = "0"
		}
		sum := uatoi(jb) + uatoi(ab)
		lg[f[1]] = words(utoa(sum) + " " + orStr(f[3], "-") + " " + orStr(f[5], "-") + " " + orStr(f[8], "-"))
		if name != "" && f[1] == name {
			lc = words(orStr(f[11], "-") + " " + orStr(f[12], "-") + " " + orStr(f[13], "-"))
		}
	}
	return lg, lc
}

// uatoi reads digits as a decimal number (bash read "010" as octal; tando-logs never prints one).
func uatoi(s string) uint64 {
	var n uint64
	for i := 0; i < len(s) && i < 19; i++ {
		n = n*10 + uint64(s[i]-'0')
	}
	return n
}

// output runs a tando program and returns what it printed on stdout, also when it failed (the
// shell passed through whatever came; the exit status was ignored).
func (c *Collector) output(ctx context.Context, stderr io.Writer, argv ...string) []byte {
	var b bytes.Buffer
	c.Env.Run.Output(ctx, run.Cmd{Argv: argv, Stdout: &b, Stderr: stderr, Timeout: helperTimeout})
	return b.Bytes()
}

func (c *Collector) stderr() io.Writer {
	if c.Stderr == nil {
		return io.Discard
	}
	return c.Stderr
}

// warn prints a message the shell's commands would have printed on stderr.
func (c *Collector) warn(msg string) {
	io.WriteString(c.stderr(), "tando-agent: "+out.Clean(msg)+"\n")
}

func or0(s string) string { return orV(s, "0") }

func orV(s, d string) string {
	if s == "" {
		return d
	}
	return s
}

// hostcareRow is "hostcare <todo> <fail> <warn> <at>" from the summary row of host care's
// summary file (/var/lib/tando/hostcare/summary, root 600: written hourly by tando-host; its
// format is docs/HOSTCARE.md's). A file read, nothing started, so tando ls stays as fast; nil
// when there is none or it cannot be read (not root). The agent's shell status prints the same.
func (c *Collector) hostcareRow() []string {
	b, err := readBounded(filepath.Join(c.Env.Lib, "hostcare", "summary"), 64<<10, false)
	if err != nil {
		return nil
	}
	for _, l := range bashread.Lines(b) {
		f := bashread.Fields(l, 8)
		if f[0] == "summary" && f[1] == "1" {
			return []string{"hostcare", f[4], f[5], f[6], f[2]}
		}
	}
	return nil
}

// cpuMinute is the agent's cpu_minute: the app's CPU over tando-metrics' last sample (about the
// last minute), per mille of one core: the usec of the last line over the seconds since the line
// before; "-" without two lines, with a gap over 10 minutes, or a last sample older than 3 minutes.
func (c *Collector) cpuMinute(name string) string {
	f, err := os.Open(filepath.Join(c.Env.Lib, "metrics", name+".tsv"))
	if err != nil {
		return "-"
	}
	defer f.Close()
	b := make([]byte, 512)
	if fi, err := f.Stat(); err == nil && fi.Size() > 512 {
		if _, err := f.Seek(fi.Size()-512, io.SeekStart); err != nil {
			return "-"
		}
	}
	n, _ := io.ReadFull(f, b)
	lines := bashread.Lines(b[:n])
	if len(lines) < 2 {
		return "-"
	}
	l1, l2 := strings.Split(lines[len(lines)-2], "\t"), strings.Split(lines[len(lines)-1], "\t")
	if len(l2) < 3 || !digits(l1[0], 12) || !digits(l2[0], 12) || !digits(l2[2], 15) {
		return "-"
	}
	t1, t2, u2 := atoi(l1[0]), atoi(l2[0]), atoi(l2[2])
	dt := t2 - t1
	if dt < 1 || dt > 600 || c.now()-t2 > 180 {
		return "-"
	}
	return decimal.Itoa(u2 / (dt * 1000))
}

func digits(s string, max int) bool { return s != "" && len(s) <= max && decimal.IsDigits(s) }
