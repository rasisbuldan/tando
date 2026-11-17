package logs

import (
	"bytes"
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"tando/srv/internal/env"
	"tando/srv/internal/out"
	"tando/srv/internal/run"
)

// host is a fake server in a temp directory: /opt/tando, /var/lib/tando, /var/log/tando, the
// journald config dir, /proc, a settable clock and fake commands (journalctl, systemctl, caddy,
// logger) answered by cmd.
type host struct {
	t      *testing.T
	l      *Logs
	dir    string
	now    int64
	calls  [][]string
	cmd    func(argv []string) (string, error) // nil: empty output
	stderr bytes.Buffer
}

type users struct{}

// users: every name is the test's own user and group (root included), so chown works unprivileged
func (users) UID(string) (int, error) { return os.Getuid(), nil }
func (users) GID(string) (int, error) { return os.Getgid(), nil }

const machineID = "0123456789abcdef0123456789abcdef"

func newHost(t *testing.T) *host { return newHostTB(t, t.TempDir()) }

// newHostB: the same host for a benchmark.
func newHostB(b *testing.B) *host { return newHostTB(&testing.T{}, b.TempDir()) }

func newHostTB(t *testing.T, dir string) *host {
	h := &host{t: t, now: 1794590000}
	h.dir = dir
	d := h.dir
	e := env.Env{Root: filepath.Join(d, "opt"), Lib: filepath.Join(d, "lib"), Cgroup: filepath.Join(d, "cg"),
		Proc: filepath.Join(d, "proc"), EUID: 0, Now: func() time.Time { return time.Unix(h.now, 0) },
		Run: run.Func(func(_ context.Context, c run.Cmd) ([]byte, error) {
			h.calls = append(h.calls, c.Argv)
			o := ""
			var err error
			if h.cmd != nil {
				o, err = h.cmd(c.Argv)
			}
			if c.Stdout != nil {
				io.WriteString(c.Stdout, o)
				return nil, err
			}
			return []byte(o), err
		})}
	h.l = &Logs{Env: e, P: Paths{LogDir: filepath.Join(d, "log/tando"), VarLog: d, Cache: filepath.Join(d, "cache"),
		Systemd: filepath.Join(d, "etc/systemd"), Journal: filepath.Join(d, "log/journal"), RunJournal: filepath.Join(d, "run/journal"),
		MachineID: filepath.Join(d, "etc/machine-id")}, Stderr: &h.stderr, Getenv: func(string) string { return "" }, PPID: 1,
		Users: users{}}
	h.write("etc/machine-id", machineID+"\n")
	h.mkdir("etc/systemd")
	return h
}

func (h *host) path(rel string) string { return filepath.Join(h.dir, rel) }

func (h *host) mkdir(rel string) {
	if err := os.MkdirAll(h.path(rel), 0o755); err != nil {
		h.t.Fatal(err)
	}
}

func (h *host) write(rel, content string) {
	h.t.Helper()
	h.mkdir(filepath.Dir(rel))
	if err := os.WriteFile(h.path(rel), []byte(content), 0o644); err != nil {
		h.t.Fatal(err)
	}
}

func (h *host) read(rel string) string {
	b, _ := os.ReadFile(h.path(rel))
	return string(b)
}

// app creates an app with an app.conf of these lines.
func (h *host) app(name string, conf ...string) {
	h.write("opt/apps/"+name+"/app.conf", strings.Join(conf, "\n")+"\n")
}

func (h *host) argvs(prog string) []string {
	var r []string
	for _, c := range h.calls {
		if c[0] == prog {
			r = append(r, strings.Join(c, " "))
		}
	}
	return r
}

// rows runs a verb writing through an out.Writer and returns its output.
func (h *host) rows(f func(w *out.Writer) error) (string, error) {
	var b bytes.Buffer
	w := out.New(&b)
	err := f(w)
	w.Flush()
	return b.String(), err
}

func wantErr(t *testing.T, err error, msg string) {
	t.Helper()
	if err == nil || err.Error() != msg {
		t.Fatalf("error %v, want %q", err, msg)
	}
}

func ctx() context.Context { return context.Background() }
