package ctl

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"tando/srv/internal/apps"
	"tando/srv/internal/buildinfo"
	"tando/srv/internal/kvfile"
	"tando/srv/internal/out"
	"tando/srv/internal/systemd"
	"tando/srv/internal/usage"
)

// AppInfo is an app in inventory and app.status. Allocated values come from its settings;
// measured ones from the last per-minute sample (informational).
type AppInfo struct {
	App        string `json:"app"`
	Recipe     string `json:"recipe"`
	State      string `json:"state"` // the web unit: active, inactive (idle or stopped), failed, ...
	Stopped    bool   `json:"stopped"`
	Down       bool   `json:"down"`
	IdleStop   string `json:"idle_stop,omitempty"`
	Current    string `json:"current,omitempty"`
	LastGood   string `json:"last_good,omitempty"`
	Phase      string `json:"phase,omitempty"`
	AllocMB    int64  `json:"alloc_mb"`
	WorkersMB  int64  `json:"alloc_workers_mb"`
	AdmittedMB int64  `json:"admitted_mb"`
	CPU        string `json:"cpu,omitempty"`
	MemMB      *int64 `json:"mem_mb"`        // measured (null: no sample yet)
	CPUms      *int64 `json:"cpu_ms_minute"` // CPU time in the last sampled minute
	SampledAt  int64  `json:"sampled_at,omitempty"`
	Awake24h   int64  `json:"awake_s_24h"` // seconds awake in the last 24 h (the ledger)
}

func (c *Ctl) host() map[string]string {
	h, _ := kvfile.Load(filepath.Join(c.Env.Root, "host.conf"))
	if h == nil {
		h = map[string]string{}
	}
	return h
}

func idleAwake(h map[string]string) int64 {
	if n, err := strconv.ParseInt(h["idle_awake"], 10, 64); err == nil && n >= 0 && n <= 100 {
		return n
	}
	return 20
}

// appInfos describes the apps (one systemctl call for all of them).
func (c *Ctl) appInfos(ctx context.Context, names []string, h map[string]string) ([]AppInfo, *Error) {
	units := make([]string, len(names))
	for i, a := range names {
		units[i] = "tando-" + a + ".service"
	}
	props, err := systemd.Show(ctx, c.Env.Run, units, "ActiveState")
	if err != nil {
		return nil, &Error{"internal", "systemd did not answer: " + clean(err.Error())}
	}
	awake := c.awakeSince(c.Env.Now().Add(-24 * time.Hour).Unix())
	ia := idleAwake(h)
	res := make([]AppInfo, 0, len(names))
	for i, a := range names {
		conf, _ := apps.Conf(c.Env.Root, a)
		st, _ := apps.State(c.Env.Root, a)
		web, workers := usage.Caps(conf)
		ai := AppInfo{App: a, Recipe: or(conf["recipe"], "node"), State: or(props[i]["ActiveState"], "unknown"),
			Stopped: st["stopped"] != "", Down: st["down"] != "", IdleStop: out.Clean(conf["idle_stop"]),
			Current: out.Clean(st["current"]), LastGood: out.Clean(st["last_good"]), Phase: out.Clean(st["phase"]),
			AllocMB: web, WorkersMB: workers, AdmittedMB: usage.Admitted(conf, ia), CPU: out.Clean(conf["cpu"]),
			Awake24h: awake[a]}
		if t, mem, cpu, ok := c.lastSample(a); ok {
			mb, ms := mem>>20, cpu/1000
			ai.MemMB, ai.CPUms, ai.SampledAt = &mb, &ms, t
		}
		res = append(res, ai)
	}
	return res, nil
}

// lastSample is the last line of the app's metrics file: time, memory bytes, CPU usec.
func (c *Ctl) lastSample(app string) (t, mem, cpu int64, ok bool) {
	b, err := readTail(filepath.Join(c.Mets, app+".tsv"), 4096)
	if err != nil {
		return 0, 0, 0, false
	}
	lines := strings.Split(strings.TrimRight(string(b), "\n"), "\n")
	f := strings.Split(lines[len(lines)-1], "\t")
	if len(f) < 3 {
		return 0, 0, 0, false
	}
	var n [3]int64
	for i := range n {
		if n[i], err = strconv.ParseInt(f[i], 10, 64); err != nil {
			return 0, 0, 0, false
		}
	}
	return n[0], n[1], n[2], true
}

// awakeSince sums the ledger's awake seconds per app over rows that ended after t.
func (c *Ctl) awakeSince(t int64) map[string]int64 { return usage.AwakeSince(c.Usage, t) }

// readTail reads at most the last n bytes of a file, from a line start.
func readTail(path string, n int64) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return nil, err
	}
	off := max(fi.Size()-n, 0)
	b := make([]byte, fi.Size()-off)
	if _, err := f.ReadAt(b, off); err != nil && err != io.EOF {
		return nil, err
	}
	if off > 0 {
		if i := strings.IndexByte(string(b), '\n'); i >= 0 {
			b = b[i+1:]
		}
	}
	return b, nil
}

func (c *Ctl) appStatus(ctx context.Context, r Request) (any, *Error) {
	if e := decodeArgs(r, &struct{}{}); e != nil {
		return nil, e
	}
	if e := c.exists(r.App); e != nil {
		return nil, e
	}
	ai, err := c.appInfos(ctx, []string{r.App}, c.host())
	if err != nil {
		return nil, err
	}
	return ai[0], nil
}

// inventory: the node's capacity, what admission has handed out, and every app.
func (c *Ctl) inventory(ctx context.Context, r Request) (any, *Error) {
	if e := decodeArgs(r, &struct{}{}); e != nil {
		return nil, e
	}
	h := c.host()
	names, err := apps.Names(c.Env.Root)
	if err != nil {
		return nil, &Error{"internal", "cannot list the apps"}
	}
	ai, aerr := c.appInfos(ctx, names, h)
	if aerr != nil {
		return nil, aerr
	}
	mi := meminfo(filepath.Join(c.Env.Proc, "meminfo"))
	oc := 1.5
	if v, err := strconv.ParseFloat(h["mem_overcommit"], 64); err == nil && v >= 0 {
		oc = v
	}
	var alloc, admitted int64
	for _, a := range ai {
		alloc += a.AllocMB + a.WorkersMB
		admitted += a.AdmittedMB
	}
	node := map[string]any{
		"version":          buildinfo.Version,
		"cpus":             runtime.NumCPU(),
		"mem_total_mb":     mi["MemTotal"] >> 10,
		"mem_available_mb": mi["MemAvailable"] >> 10,
		"swap_total_mb":    mi["SwapTotal"] >> 10,
		"load1":            load1(filepath.Join(c.Env.Proc, "loadavg")),
		"mem_overcommit":   oc,
		"idle_awake_pct":   idleAwake(h),
		"alloc_mb":         alloc,
		"admitted_mb":      admitted,
		"apps":             len(ai),
		"draining":         c.draining(),
	}
	if oc > 0 {
		limit := int64(float64(mi["MemTotal"]>>10) * oc)
		node["admit_limit_mb"] = limit
		node["admit_headroom_mb"] = limit - admitted
	}
	var st syscall.Statfs_t
	if syscall.Statfs(c.Env.Root, &st) == nil {
		bs := int64(st.Bsize)
		node["disk_total_mb"] = int64(st.Blocks) * bs >> 20
		node["disk_free_mb"] = int64(st.Bavail) * bs >> 20
	}
	return map[string]any{"node": node, "apps": ai}, nil
}

func meminfo(path string) map[string]int64 {
	m := map[string]int64{}
	b, _ := os.ReadFile(path)
	for l := range strings.SplitSeq(string(b), "\n") {
		k, v, ok := strings.Cut(l, ":")
		if !ok {
			continue
		}
		f := strings.Fields(v)
		if len(f) > 0 {
			if n, err := strconv.ParseInt(f[0], 10, 64); err == nil {
				m[k] = n // kB
			}
		}
	}
	return m
}

func load1(path string) float64 {
	b, _ := os.ReadFile(path)
	f := strings.Fields(string(b))
	if len(f) == 0 {
		return 0
	}
	v, _ := strconv.ParseFloat(f[0], 64)
	return v
}

// Alert is one alert that is not ok (tando-watch's state).
type Alert struct {
	Scope  string `json:"scope"` // an app, or "host"
	Check  string `json:"check"`
	State  string `json:"state"` // firing | pending
	Since  int64  `json:"since,omitempty"`
	Detail string `json:"detail,omitempty"`
}

// alerts: the alerts that are firing or pending (of one app, when app is given).
func (c *Ctl) alerts(_ context.Context, r Request) (any, *Error) {
	if e := decodeArgs(r, &struct{}{}); e != nil {
		return nil, e
	}
	st, _ := kvfile.Load(c.Alerts)
	res := []Alert{}
	for k, v := range st {
		key, ok := strings.CutSuffix(k, ".st")
		if !ok || (v != "firing" && v != "pending") || strings.HasPrefix(key, "_nf.") {
			continue
		}
		scope, check, ok := strings.Cut(key, ".")
		if !ok {
			continue
		}
		if scope == "_host" {
			scope = "host"
		}
		if r.App != "" && scope != r.App {
			continue
		}
		since, _ := strconv.ParseInt(st[key+".since"], 10, 64)
		res = append(res, Alert{Scope: out.Clean(scope), Check: out.Clean(check), State: v, Since: since, Detail: out.Clean(st[key+".det"])})
	}
	sort.Slice(res, func(i, j int) bool {
		if res[i].Scope != res[j].Scope {
			return res[i].Scope < res[j].Scope
		}
		return res[i].Check < res[j].Check
	})
	return map[string]any{"alerts": res}, nil
}
