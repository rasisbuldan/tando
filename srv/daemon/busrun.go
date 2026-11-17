package daemon

import (
	"context"
	"strings"
	"sync"
	"time"

	"tando/srv/internal/run"
	"tando/srv/internal/sdbus"
)

// busRunner answers `systemctl show` over systemd's private bus, on one connection kept open,
// for every package the daemon runs (watch, metrics): the answer is what systemctl prints, so
// they do not know. Any other command, a property it cannot place, or a bus that fails goes to
// the real runner (systemctl as before). A systemctl start costs some 5 ms of CPU in systemctl
// and in systemd; a Get on an open connection a few hundred microseconds.
type busRunner struct {
	inner run.Runner
	path  string                  // sdbus.Socket
	dial  func() (unitBus, error) // nil: sdbus.Dial(path); tests answer from captured values

	mu   sync.Mutex
	conn unitBus
}

// unitBus is what busRunner asks of the bus (an *sdbus.Conn).
type unitBus interface {
	Loaded(pattern string) (map[string]string, error)
	Get(units []string, props []sdbus.Prop) ([]map[string]string, error)
	SetDeadline(t time.Time) error
	Close() error
}

// propIface: the D-Bus interface of each property the checks and the sample read.
var propIface = map[string]string{
	"ActiveState": "org.freedesktop.systemd1.Unit", "SubState": "org.freedesktop.systemd1.Unit",
	"ActiveEnterTimestampMonotonic": "org.freedesktop.systemd1.Unit",
	"Result":                        "org.freedesktop.systemd1.Service", "NRestarts": "org.freedesktop.systemd1.Service",
	"MemoryMax": "org.freedesktop.systemd1.Service", "ExecMainCode": "org.freedesktop.systemd1.Service",
	"ExecMainStatus": "org.freedesktop.systemd1.Service", "CPUUsageNSec": "org.freedesktop.systemd1.Service",
	"ExecMainStartTimestampMonotonic": "org.freedesktop.systemd1.Service", "StatusText": "org.freedesktop.systemd1.Service",
	"MainPID": "org.freedesktop.systemd1.Service",
}

// freshProps is what `systemctl show` prints for a service unit systemd has not loaded (a stopped
// app): asking would load and parse its unit file every minute.
var freshProps = map[string]string{"ActiveState": "inactive", "SubState": "dead", "Result": "success",
	"NRestarts": "0", "ExecMainCode": "0", "ExecMainStatus": "0", "ActiveEnterTimestampMonotonic": "0",
	"ExecMainStartTimestampMonotonic": "0", "MainPID": "0"}

func (b *busRunner) Output(ctx context.Context, c run.Cmd) ([]byte, error) {
	a := c.Argv
	if len(a) >= 5 && a[0] == "systemctl" && a[1] == "show" && (a[2] == "-p" || a[2] == "-P") {
		if out, ok := b.show(a[2] == "-P", strings.Split(a[3], ","), a[4:]); ok {
			return out, nil
		}
	}
	return b.inner.Output(ctx, c)
}

// show formats what systemctl would print: "-p": "Key=value" lines, a block per unit; "-P": the
// value alone (one property, one unit).
func (b *busRunner) show(bare bool, names, units []string) ([]byte, bool) {
	if bare && (len(names) != 1 || len(units) != 1) {
		return nil, false
	}
	props := make([]sdbus.Prop, len(names))
	for i, n := range names {
		iface, ok := propIface[n]
		if !ok || (iface == "org.freedesktop.systemd1.Service" && !allServices(units)) {
			return nil, false
		}
		props[i] = sdbus.Prop{Iface: iface, Name: n}
	}
	res, err := b.get(units, props)
	if err != nil {
		return nil, false
	}
	var s strings.Builder
	for i, m := range res {
		if bare {
			s.WriteString(m[names[0]] + "\n")
			break
		}
		if i > 0 {
			s.WriteByte('\n')
		}
		for _, n := range names {
			s.WriteString(n + "=" + m[n] + "\n")
		}
	}
	return []byte(s.String()), true
}

func allServices(units []string) bool {
	for _, u := range units {
		if !strings.HasSuffix(u, ".service") {
			return false
		}
	}
	return true
}

// get asks on the open connection (dialled again after a failure). Apps' units that systemd has
// not loaded are not asked (see freshProps); their MemoryMax reads as not set, which the checks
// only use while the app runs.
func (b *busRunner) get(units []string, props []sdbus.Prop) ([]map[string]string, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for try := 0; try < 2; try++ {
		if b.conn == nil {
			var c unitBus
			var err error
			if b.dial != nil {
				c, err = b.dial()
			} else {
				c, err = sdbus.Dial(b.path, 5*time.Second)
			}
			if err != nil {
				return nil, err
			}
			b.conn = c
		}
		b.conn.SetDeadline(time.Now().Add(10 * time.Second))
		res, err := b.ask(units, props)
		if err == nil {
			b.conn.SetDeadline(time.Time{})
			return res, nil
		}
		b.conn.Close()
		b.conn = nil
	}
	return nil, errBus
}

type busError struct{}

func (busError) Error() string { return "systemd bus failed" }

var errBus error = busError{}

func (b *busRunner) ask(units []string, props []sdbus.Prop) ([]map[string]string, error) {
	loaded, err := b.conn.Loaded("tando-*")
	if err != nil {
		return nil, err
	}
	var in []string
	var inIdx []int
	res := make([]map[string]string, len(units))
	for i, u := range units {
		_, isLoaded := loaded[u]
		if strings.HasPrefix(u, "tando-") && !isLoaded {
			m := map[string]string{}
			for _, p := range props {
				m[p.Name] = freshProps[p.Name] // ("" for MemoryMax, CPUUsageNSec: not set)
			}
			res[i] = m
			continue
		}
		in, inIdx = append(in, u), append(inIdx, i)
	}
	got, err := b.conn.Get(in, props)
	if err != nil {
		return nil, err
	}
	for k, i := range inIdx {
		res[i] = got[k]
	}
	return res, nil
}

func (b *busRunner) close() {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.conn != nil {
		b.conn.Close()
		b.conn = nil
	}
}
