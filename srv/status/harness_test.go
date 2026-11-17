package status

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"tando/srv/internal/env"
	"tando/srv/internal/run"
)

// host is a fake server: a temp tree for /opt/tando, /var/lib/tando, /sys/fs/cgroup, /proc, /sys
// and Caddy's certificates; a fixed clock; a runner that answers systemctl and the tando programs.
type host struct {
	t    *testing.T
	dir  string
	now  int64
	euid int
	// units: systemctl show answers per unit (missing: ActiveState=inactive)
	units map[string]map[string]string
	// showFails makes systemctl show fail
	showFails bool
	// act: ActiveState of activation units (systemctl show -P)
	act map[string]string
	// programs: stdout of the tando programs by argv[1:] joined with spaces
	programs map[string]string
	stderr   bytes.Buffer
	mu       sync.Mutex
	calls    []string
	// onRecover runs when tando-agent recover is called
	onRecover func()
	net       func() (string, []string)
}

func newHost(t *testing.T) *host {
	h := &host{t: t, dir: t.TempDir(), now: 1_800_000_000, units: map[string]map[string]string{},
		act: map[string]string{}, programs: map[string]string{}}
	for _, d := range []string{"root/apps", "root/bin", "lib", "cgroup/system.slice", "proc", "sys/devices/system/cpu", "certs"} {
		os.MkdirAll(filepath.Join(h.dir, d), 0o755)
	}
	h.write("proc/uptime", "5000.42 9000.00\n")
	h.write("proc/loadavg", "0.52 0.40 0.30 1/200 12345\n")
	h.write("proc/meminfo", "MemTotal:        2000000 kB\nMemFree:          100000 kB\nMemAvailable:    1500000 kB\n")
	h.write("proc/sys/kernel/hostname", "box\n")
	h.write("sys/devices/system/cpu/online", "0-1,3\n")
	h.write("root/host.conf", "apps_domain=example.org\npublic_port=8080\ntls=off\n")
	return h
}

func (h *host) path(p string) string { return filepath.Join(h.dir, p) }

func (h *host) write(p, data string) {
	h.t.Helper()
	f := h.path(p)
	if err := os.MkdirAll(filepath.Dir(f), 0o755); err != nil {
		h.t.Fatal(err)
	}
	if err := os.WriteFile(f, []byte(data), 0o644); err != nil {
		h.t.Fatal(err)
	}
}

// app makes apps/<name> with app.conf and state (state "" = no state file).
func (h *host) app(name, conf, state string) {
	h.write("root/apps/"+name+"/app.conf", conf)
	if state != "" {
		h.write("root/apps/"+name+"/state", state)
	}
	os.MkdirAll(h.path("root/apps/"+name+"/releases"), 0o755)
	os.MkdirAll(h.path("root/apps/"+name+"/incoming"), 0o755)
}

// program makes an executable tando program in root/bin answering args with stdout.
func (h *host) program(name string) {
	h.write("root/bin/"+name, "#!fake\n")
	os.Chmod(h.path("root/bin/"+name), 0o755)
}

func (h *host) collector() *Collector {
	e := env.Env{
		Root:   h.path("root"),
		Lib:    h.path("lib"),
		Cgroup: h.path("cgroup"),
		Proc:   h.path("proc"),
		EUID:   h.euid,
		Now:    func() time.Time { return time.Unix(h.now, 0) },
		Run:    run.Func(h.run),
	}
	c := New(e)
	c.Sys = h.path("sys")
	c.Certs = h.path("certs")
	c.MuslDir = h.path("lib-musl")
	c.Dpkg = h.path("dpkg-status")
	c.Stderr = &h.stderr
	c.Bus = "" // (never the machine's systemd: the runner answers)
	c.Statfs = func(string) (uint64, uint64, error) { return 1000, 400, nil }
	c.Net = h.net
	if c.Net == nil {
		c.Net = func() (string, []string) { return "10.0.0.2", []string{"10.0.0.2", "2001:db8::2"} }
	}
	return c
}

func (h *host) run(ctx context.Context, c run.Cmd) ([]byte, error) {
	h.mu.Lock()
	h.calls = append(h.calls, strings.Join(c.Argv, " "))
	h.mu.Unlock()
	reply := func(s string) ([]byte, error) {
		if c.Stdout != nil {
			c.Stdout.Write([]byte(s))
			return nil, nil
		}
		return []byte(s), nil
	}
	a := c.Argv
	switch {
	case a[0] == "systemctl" && len(a) > 2 && a[1] == "show" && a[2] == "-P":
		if s, ok := h.act[a[len(a)-1]]; ok {
			return reply(s + "\n")
		}
		return reply("inactive\n")
	case a[0] == "systemctl" && len(a) > 3 && a[1] == "show":
		if h.showFails {
			return nil, errors.New("systemctl: Failed to connect to bus")
		}
		var b strings.Builder
		for i, u := range a[4:] {
			if i > 0 {
				b.WriteString("\n")
			}
			m := h.units[u]
			if st, ok := h.act[strings.TrimSuffix(u, ".service")]; ok {
				m = map[string]string{"ActiveState": st}
			}
			if m == nil {
				m = map[string]string{"ActiveState": "inactive", "MemoryMax": "infinity", "CPUUsageNSec": "[not set]",
					"NRestarts": "0", "ActiveEnterTimestampMonotonic": "0"}
			}
			for _, k := range []string{"NRestarts", "ActiveState", "ActiveEnterTimestampMonotonic", "MemoryMax", "CPUUsageNSec"} {
				if v, ok := m[k]; ok {
					fmt.Fprintf(&b, "%s=%s\n", k, v)
				}
			}
		}
		return reply(b.String())
	case strings.HasPrefix(a[0], h.path("root/bin/")):
		name := filepath.Base(a[0])
		key := strings.Join(append([]string{name}, a[1:]...), " ")
		if name == "tando-agent" && len(a) > 1 && a[1] == "recover" && h.onRecover != nil {
			h.onRecover()
		}
		if name == "tando-watch" && c.Stderr != nil {
			fmt.Fprint(c.Stderr, h.programs[key+" #stderr"])
		}
		return reply(h.programs[key])
	case filepath.Base(a[0]) == "node" || filepath.Base(a[0]) == "caddy" || filepath.Base(a[0]) == "python3":
		return reply(h.programs[filepath.Base(a[0])])
	}
	return nil, fmt.Errorf("%s: not faked", a[0])
}

func (h *host) called(prefix string) int {
	n := 0
	for _, c := range h.calls {
		if strings.HasPrefix(c, prefix) {
			n++
		}
	}
	return n
}

// out runs a verb and returns its output; the error when want is "error:...".
func (h *host) out(f func(c *Collector, b *bytes.Buffer) error) (string, error) {
	h.t.Helper()
	var b bytes.Buffer
	err := f(h.collector(), &b)
	return b.String(), err
}

func eq(t *testing.T, got, want string) {
	t.Helper()
	if got != want {
		t.Errorf("got:\n%s\nwant:\n%s", strings.ReplaceAll(got, "\t", "→"), strings.ReplaceAll(want, "\t", "→"))
	}
}

func rows(r ...string) string {
	if len(r) == 0 {
		return ""
	}
	return strings.Join(r, "\n") + "\n"
}

func tab(f ...string) string { return strings.Join(f, "\t") }
