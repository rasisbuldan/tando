package watch

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"tando/srv/internal/bashread"
	"tando/srv/internal/decimal"
	"tando/srv/internal/env"
	"tando/srv/internal/kvfile"
	"tando/srv/internal/out"
	"tando/srv/internal/run"
)

// fakeHost is a tando host in a temp directory: a fixed clock that tests move, systemctl,
// journalctl, tando-logs, du, nft and systemd-run answered by a run.Func, health probes and
// notifier deliveries answered in memory.
type fakeHost struct {
	t    *testing.T
	root string
	now  time.Time

	mu      sync.Mutex
	units   map[string]map[string]string // unit -> properties (systemctl show)
	scan    string                       // tando-logs watch-scan output
	journal map[string]string            // a substring of the journalctl argv -> output
	du      string                       // du's total in MB
	calls   [][]string                   // every command started
	probe   map[string]probeRes          // health probe result by URL (default: 200 ok)
	direct  int                          // liveness's direct probe status
	slow    time.Duration                // how long the direct probe takes
	sends   []sent
	code    int // the receivers' answer
	pings   int
	cache   *Cache   // kept between runs, as tandod does (nil: none)
	disks   []string // measured by the host disk check (none: the laptop's disk is no fixture)
	boot    int64    // when the fake host started (its /proc/uptime follows the clock)
	pg      string   // psql's answer about the connections (the m and r rows); pgErr: it fails with this
	pgSizes string   // its answer about the sizes (the d rows), given only when asked
	pgErr   string
	pgStat  map[string]string // its answer to each other statement (the database's numbers), by SQL
	pgCmds  []run.Cmd         // every psql started
}

func (f *fakeHost) setUptime() {
	f.write("proc/uptime", decimal.Itoa(f.now.Unix()-f.boot)+".12 1.00\n")
}

type sent struct {
	url    string
	header [][2]string
	body   string
}

func newFakeHost(t *testing.T) *fakeHost {
	f := &fakeHost{t: t, root: t.TempDir(), now: time.Unix(1_800_000_000, 0),
		units: map[string]map[string]string{}, journal: map[string]string{}, probe: map[string]probeRes{}, code: 200}
	for _, d := range []string{"opt/apps", "opt/bin", "lib/watch/out", "lib/watch/inbox", "opt/alerts.d", "run", "units", "caddy",
		"cgroup/tando.slice", "proc/1", "proc/self", "proc/sys/kernel", "proc/pressure"} {
		os.MkdirAll(f.path(d), 0o700)
	}
	f.boot = f.now.Unix() - 100000
	f.setUptime()
	f.write("proc/1/stat", "1 (systemd) S 0 1 1 0 -1 4194560 1 2 3 4 5 6 7 8 20 0 1 0 1000 1 1\n")
	f.write("proc/self/status", "Name:\tx\nCpus_allowed_list:\t0-1\n")
	f.write("proc/meminfo", "MemTotal: 2000000 kB\nMemFree: 1000 kB\nMemAvailable: 1000000 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n")
	f.write("proc/loadavg", "0.10 0.20 0.30 1/100 5\n")
	f.write("proc/sys/kernel/hostname", "testhost\n")
	f.unit("caddy.service", "active", "running", "0")
	return f
}

func (f *fakeHost) path(p string) string { return filepath.Join(f.root, p) }

func (f *fakeHost) write(p, data string) {
	f.t.Helper()
	os.MkdirAll(filepath.Dir(f.path(p)), 0o700)
	if err := os.WriteFile(f.path(p), []byte(data), 0o600); err != nil {
		f.t.Fatal(err)
	}
}

func (f *fakeHost) unit(u, active, sub, nrestarts string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.units[u] = map[string]string{"ActiveState": active, "SubState": sub, "Result": "success", "NRestarts": nrestarts,
		"MemoryMax": "100000000", "ExecMainCode": "0", "ExecMainStatus": "0"}
}

// app adds an app with a release and a running unit.
func (f *fakeHost) app(name string, conf ...string) {
	c := "port=4100\nhealth=/health\nrecipe=node\nmemory=96M\n" + strings.Join(conf, "\n") + "\n"
	f.write("opt/apps/"+name+"/app.conf", c)
	f.write("opt/apps/"+name+"/state", "current=20261114-170102\nphase=idle\n")
	os.MkdirAll(f.path("opt/apps/"+name+"/shared"), 0o700)
	if !strings.Contains(c, "recipe=static") {
		f.unit("tando-"+name+".service", "active", "running", "0")
	}
}

func (f *fakeHost) notifier(name, conf string) { f.write("opt/alerts.d/notify-"+name, conf) }

func (f *fakeHost) settings(s ...string) { f.write("opt/alerts.conf", strings.Join(s, "\n")+"\n") }

func (f *fakeHost) watch() Watch {
	e := env.Env{Root: f.path("opt"), Lib: f.path("lib"), Cgroup: f.path("cgroup"), Proc: f.path("proc"), EUID: 0,
		Now: func() time.Time { return f.now }, Run: run.Func(f.cmd)}
	w := New(e, 4242)
	w.RunDir, w.Units, w.Caddy = f.path("run"), f.path("units"), f.path("caddy")
	w.Disks = f.disks
	w.Cache = f.cache
	w.Probe, w.Certs, w.Send = f, f, f
	return w
}

func (f *fakeHost) cmd(ctx context.Context, c run.Cmd) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, c.Argv)
	argv := c.Argv
	if argv[0] == "nice" {
		argv = argv[1:]
	}
	switch filepath.Base(argv[0]) {
	case "systemctl":
		if len(argv) > 2 && (argv[1] == "start" || argv[1] == "try-restart" || argv[1] == "restart") {
			if u := f.units[argv[2]]; u != nil { // (started: active, with the pid it was given)
				u["ActiveState"] = "active"
				if p := u["NextPID"]; p != "" {
					u["MainPID"] = p
				}
			}
			return nil, nil
		}
		if len(argv) > 2 && argv[1] == "show" && argv[2] == "-P" {
			return []byte(f.units[argv[4]][argv[3]] + "\n"), nil
		}
		if len(argv) > 1 && argv[1] == "show" {
			var b strings.Builder
			for i, u := range argv[4:] {
				if i > 0 {
					b.WriteString("\n")
				}
				p := f.units[u]
				if p == nil {
					p = map[string]string{"ActiveState": "inactive", "SubState": "dead", "Result": "success", "NRestarts": "0"}
				}
				for _, k := range strings.Split(argv[3], ",") {
					b.WriteString(k + "=" + p[k] + "\n")
				}
			}
			return []byte(b.String()), nil
		}
		return nil, nil
	case "journalctl":
		j := strings.Join(argv, " ")
		for k, v := range f.journal {
			if strings.Contains(j, k) {
				return []byte(v), nil
			}
		}
		return nil, nil
	case "tando-logs":
		if argv[1] == "watch-scan" {
			return []byte(f.scan), nil
		}
		return nil, nil
	case "psql":
		f.pgCmds = append(f.pgCmds, c)
		if f.pgErr != "" {
			return nil, errors.New(f.pgErr)
		}
		// each statement's rows, in the order given (one that "fails" has none: its error goes to
		// stderr, and the exit status is the last statement's)
		var b strings.Builder
		for _, a := range argv {
			switch sql, _ := strings.CutPrefix(a, "--command="); sql {
			case pgSizesSQL:
				b.WriteString(f.pgSizes)
			case pgConnsSQL:
				b.WriteString(f.pg)
			default:
				b.WriteString(f.pgStat[sql])
			}
		}
		return []byte(b.String()), nil
	case "du":
		return []byte(f.du + "\t" + argv[len(argv)-1] + "\n" + f.du + "\ttotal\n"), nil
	}
	return nil, nil
}

func (f *fakeHost) Probe(ctx context.Context, reqs []probeReq, timeout time.Duration) []probeRes {
	f.mu.Lock()
	defer f.mu.Unlock()
	res := make([]probeRes, len(reqs))
	for i, r := range reqs {
		if p, ok := f.probe[r.url]; ok {
			res[i] = p
		} else {
			res[i] = probeRes{code: 200, ms: 12, body: "ok\n"}
		}
	}
	return res
}

func (f *fakeHost) Direct(ctx context.Context, url string) int {
	time.Sleep(f.slow)
	return f.direct
}

func (f *fakeHost) Cert(ctx context.Context, site string, verify bool) (time.Time, time.Time, error) {
	return f.now.Add(-80 * 24 * time.Hour), f.now.Add(10 * 24 * time.Hour), nil
}

func (f *fakeHost) Post(ctx context.Context, url string, h [][2]string, body []byte) (int, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sends = append(f.sends, sent{url, h, string(body)})
	return f.code, nil
}

func (f *fakeHost) Ping(ctx context.Context, url string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.pings++
	return nil
}

// tick runs `run` once and moves the clock a minute on.
func (f *fakeHost) tick() {
	f.t.Helper()
	f.setUptime()
	if err := f.watch().Run(context.Background()); err != nil {
		f.t.Fatalf("run: %v", err)
	}
	f.now = f.now.Add(time.Minute)
}

func (f *fakeHost) ticks(n int) {
	f.t.Helper()
	for range n {
		f.tick()
	}
}

func (f *fakeHost) state() map[string]string {
	m, _ := kvfile.Load(f.path("lib/watch/state"))
	return m
}

func (f *fakeHost) vstate() map[string]string {
	m, _ := kvfile.Load(f.path("run/vstate"))
	return m
}

func (f *fakeHost) st(k string) string { return f.state()[k] }

// history lines' "kind app check" since the start.
func (f *fakeHost) history() []string {
	b, _ := os.ReadFile(f.path("lib/watch/history.tsv"))
	var res []string
	for _, l := range bashread.Lines(b) {
		p := strings.Split(l, "\t")
		res = append(res, p[1]+" "+p[2]+" "+p[3])
	}
	return res
}

func (f *fakeHost) count(hist []string, ev string) int {
	n := 0
	for _, h := range hist {
		if h == ev {
			n++
		}
	}
	return n
}

// sentBodies are the bodies sent so far; reset clears them.
func (f *fakeHost) sentBodies() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	var res []string
	for _, s := range f.sends {
		res = append(res, s.body)
	}
	return res
}

func (f *fakeHost) reset() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sends, f.calls = nil, nil
}

func (f *fakeHost) called(prefix string) [][]string {
	f.mu.Lock()
	defer f.mu.Unlock()
	var res [][]string
	for _, c := range f.calls {
		if strings.HasPrefix(strings.Join(c, " "), prefix) {
			res = append(res, c)
		}
	}
	return res
}

func (f *fakeHost) queueFiles(name string) []string {
	m, _ := filepath.Glob(f.path("lib/watch/out/" + name + "/*"))
	sort.Strings(m)
	return m
}

// do runs a verb and returns what it printed.
func do(fn func(o *out.Writer) error) (string, error) {
	var b strings.Builder
	o := out.New(&b)
	err := fn(o)
	o.Flush()
	return b.String(), err
}
