package daemon

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"tando/srv/internal/run"
	"tando/srv/internal/sdbus"
)

// What a test server (systemd 259) answered, captured with busctl (the bus) and `systemctl show`
// for an app that runs, one stopped with tando stop (not loaded), one failed, a unit that does
// not exist, and Caddy. The bus values are as sdbus decodes them ("infinity", the largest uint64,
// reads as "").
var capturedLoaded = map[string]string{"tando-run1.service": "active", "tando-fail1.service": "failed"}

var capturedBus = map[string]map[string]string{
	"tando-run1.service": {"ActiveState": "active", "SubState": "running", "Result": "success", "NRestarts": "0",
		"MemoryMax": "67108864", "ExecMainCode": "0", "ExecMainStatus": "0"},
	"tando-fail1.service": {"ActiveState": "failed", "SubState": "failed", "Result": "exit-code", "NRestarts": "0",
		"MemoryMax": "67108864", "ExecMainCode": "0", "ExecMainStatus": "0"},
	"caddy.service": {"ActiveState": "active", "SubState": "running", "Result": "success", "NRestarts": "0",
		"MemoryMax": "", "ExecMainCode": "0", "ExecMainStatus": "0"},
}

const capturedSystemctl = `ActiveState=active
SubState=running
Result=success
NRestarts=0
ExecMainCode=0
ExecMainStatus=0
MemoryMax=67108864

ActiveState=inactive
SubState=dead
Result=success
NRestarts=0
ExecMainCode=0
ExecMainStatus=0
MemoryMax=67108864

ActiveState=failed
SubState=failed
Result=exit-code
NRestarts=0
ExecMainCode=0
ExecMainStatus=0
MemoryMax=67108864

ActiveState=inactive
SubState=dead
Result=success
NRestarts=0
ExecMainCode=0
ExecMainStatus=0
MemoryMax=infinity

ActiveState=active
SubState=running
Result=success
NRestarts=0
ExecMainCode=0
ExecMainStatus=0
MemoryMax=infinity
`

type fakeBus struct {
	gets   int
	fail   bool
	loaded int
}

func (f *fakeBus) Loaded(string) (map[string]string, error) {
	f.loaded++
	if f.fail {
		return nil, errors.New("bus broke")
	}
	return capturedLoaded, nil
}

func (f *fakeBus) Get(units []string, props []sdbus.Prop) ([]map[string]string, error) {
	f.gets++
	res := make([]map[string]string, len(units))
	for i, u := range units {
		m, ok := capturedBus[u]
		if !ok {
			return nil, errors.New("asked about a unit that is not loaded: " + u) // (it would load it)
		}
		res[i] = map[string]string{}
		for _, p := range props {
			res[i][p.Name] = m[p.Name]
		}
	}
	return res, nil
}

func (f *fakeBus) SetDeadline(time.Time) error { return nil }
func (f *fakeBus) Close() error                { return nil }

func blocks(s string) []map[string]string {
	var res []map[string]string
	for _, b := range strings.Split(strings.TrimSpace(s), "\n\n") {
		m := map[string]string{}
		for _, l := range strings.Split(b, "\n") {
			k, v, _ := strings.Cut(l, "=")
			m[k] = v
		}
		res = append(res, m)
	}
	return res
}

func TestBusRunnerMatchesSystemctl(t *testing.T) {
	fb := &fakeBus{}
	var execs []string
	inner := run.Func(func(_ context.Context, c run.Cmd) ([]byte, error) {
		execs = append(execs, strings.Join(c.Argv, " "))
		return []byte("from systemctl\n"), nil
	})
	b := &busRunner{inner: inner, dial: func() (unitBus, error) { return fb, nil }}
	units := []string{"tando-run1.service", "tando-stop1.service", "tando-fail1.service", "tando-nope.service", "caddy.service"}
	props := "ActiveState,SubState,Result,NRestarts,MemoryMax,ExecMainCode,ExecMainStatus"
	out, err := b.Output(context.Background(), run.Cmd{Argv: append([]string{"systemctl", "show", "-p", props}, units...)})
	if err != nil || len(execs) != 0 {
		t.Fatalf("%v, execs %v", err, execs)
	}
	got, want := blocks(string(out)), blocks(capturedSystemctl)
	if len(got) != len(want) {
		t.Fatalf("%d blocks:\n%s", len(got), out)
	}
	for i, u := range units {
		for _, p := range strings.Split(props, ",") {
			g, w := got[i][p], want[i][p]
			switch {
			case p == "MemoryMax" && w == "infinity" && g == "": // no number: no limit, to every caller
			case p == "MemoryMax" && u == "tando-stop1.service" && g == "": // not loaded: not asked
			case g != w:
				t.Errorf("%s %s: bus %q, systemctl %q", u, p, g, w)
			}
		}
	}
	// -P: one value
	out, _ = b.Output(context.Background(), run.Cmd{Argv: []string{"systemctl", "show", "-P", "ActiveState", "tando-fail1.service"}})
	if string(out) != "failed\n" {
		t.Errorf("-P: %q", out)
	}
	// a property it cannot place, another command: systemctl itself
	b.Output(context.Background(), run.Cmd{Argv: []string{"systemctl", "show", "-p", "Names", "caddy.service"}})
	b.Output(context.Background(), run.Cmd{Argv: []string{"journalctl", "-n", "1"}})
	if len(execs) != 2 {
		t.Errorf("fell through: %v", execs)
	}
	// a broken bus: systemctl, and a new connection next time
	fb.fail = true
	out, _ = b.Output(context.Background(), run.Cmd{Argv: []string{"systemctl", "show", "-P", "ActiveState", "caddy.service"}})
	if string(out) != "from systemctl\n" || b.conn != nil {
		t.Errorf("broken bus: %q, conn %v", out, b.conn)
	}
	fb.fail = false
	out, _ = b.Output(context.Background(), run.Cmd{Argv: []string{"systemctl", "show", "-P", "ActiveState", "caddy.service"}})
	if string(out) != "active\n" {
		t.Errorf("reconnected: %q", out)
	}
}

func TestTimerOn(t *testing.T) {
	for _, tt := range []struct {
		answer string
		err    error
		on     bool
	}{{"active\n", nil, true}, {"inactive\n", nil, false}, {"failed", nil, false}, {"", errors.New("no bus"), true},
		{"activating", nil, true}, {"", nil, true}} {
		if got := timerOn(tt.answer, tt.err); got != tt.on {
			t.Errorf("timerOn(%q, %v) = %v", tt.answer, tt.err, got)
		}
	}
}
