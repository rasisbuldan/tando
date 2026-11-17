// Package status answers the read-only, frequently called verbs of tando-agent: status (tando ls,
// tando status, tando top, --watch), deploy-status (polled during every deploy), releases,
// history, busy and info. tando-agent execs /opt/tando/bin/tando-status for them; their output is
// the agent's, byte for byte (the client parses it with fixed field positions), so the comments
// here quote the shell code they replace.
//
// Cost: one `systemctl show` for all apps, the cgroup and /proc files read directly, statfs
// instead of df, and the other tando programs whose output status includes (tando-logs
// log-stats, tando-metrics read, tando-watch brief) started once each. Nothing is started per app.
//
// A Collector has explicit inputs (Env, paths, the clock, a Runner) and no global state, so a
// long-running process can call it again and again; formatting is in pure functions (HostRow,
// AppRow, ReleaseRows, ...).
//
// Layer: domain. It imports internal/* only (internal/sdbus for systemd's bus); no other domain
// package, not daemon or daemon/proto: the rows of tando-logs, tando-watch and tando-metrics come
// from those programs or through interfaces tandod fills (rows.go), and the answer of tandod
// through a Remote main passes.
package status

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sync"
	"time"

	"tando/srv/internal/env"
	"tando/srv/internal/sdbus"
	"tando/srv/internal/valid"
)

// Collector answers the verbs for one machine. Its methods may run at once (a long-running
// caller): the one thing it keeps, the connection to systemd, is guarded; set the fields before
// the first call.
type Collector struct {
	Env env.Env
	// Sys is /sys (the CPUs online), Certs Caddy's certificate store, MuslDir where a musl
	// loader would be (/lib), Dpkg the dpkg status file (a key of the tool version cache).
	Sys, Certs, MuslDir, Dpkg string
	// SudoUser owns an incoming/ that `app` recreates (install -d -o "${SUDO_USER:-root}").
	SudoUser string
	// ToolPath is where info looks for python3, node and caddy ("": SecurePath).
	ToolPath string
	// AgentEnv is the environment of `tando-agent recover` (deploy-status): the agent's PATH and
	// locale, its sudo variables. nil: run.BaseEnv.
	AgentEnv []string
	// Stderr receives what the shell let through to the client's stderr (tando-watch brief's
	// messages, a failed systemctl).
	Stderr io.Writer
	// Statfs measures a file system (df -Pk): total and used KiB. nil: statfs(2).
	Statfs func(path string) (totalKB, usedKB uint64, err error)
	// Bus is systemd's private bus socket (sdbus.Socket), asked as root instead of systemctl; ""
	// always runs systemctl.
	Bus   string
	busMu sync.Mutex // guards bus: a long-running caller may serve several requests at once
	bus   *sdbus.Conn
	// UnitRoot is prefixed to systemd's unit directories when a stopped app's unit file is read
	// ("" on the machine itself; tests).
	UnitRoot string
	// LogRows, AlertRows and TrendRows give the other programs' rows in-process (rows.go); nil:
	// the programs are started.
	LogRows   LogRows
	AlertRows AlertRows
	TrendRows TrendRows
	// Trace, when set, is told how status was answered (StatusVia; TANDO_STATUS_TRACE=1, tests).
	Trace io.Writer
	// Net gives the source address of the route to 1.1.1.1 and the global addresses
	// (ip route get, ip addr show scope global). nil: netlink and a UDP socket.
	Net func() (src string, addrs []string)
}

// New is a Collector for the real machine.
func New(e env.Env) *Collector {
	return &Collector{
		Env:     e,
		Sys:     "/sys",
		Certs:   "/var/lib/caddy/.local/share/caddy/certificates",
		MuslDir: "/lib",
		Dpkg:    "/var/lib/dpkg/status",
		Bus:     sdbus.Socket,
		Stderr:  io.Discard,
	}
}

// soakDefault is the agent's SOAK: seconds a new release must stay up after the check.
const soakDefault = "30"

// Error is a message the agent's `die` printed ("tando-agent: <message>", exit 1); the client
// matches some of them word for word ("no such app: x").
type Error struct{ Msg string }

func (e *Error) Error() string { return e.Msg }

func die(msg string) error { return &Error{Msg: msg} }

// isDie reports whether err is one of the agent's own messages (and not a failure to run).
func isDie(err error) bool { var e *Error; return errors.As(err, &e) }

func (c *Collector) appDir(a string) string { return filepath.Join(c.Env.Root, "apps", a) }
func (c *Collector) bin(name string) string { return filepath.Join(c.Env.Root, "bin", name) }
func (c *Collector) now() int64             { return c.Env.Now().Unix() }

// app is the agent's `app`: an app selected by name, with its app.conf and state (host.conf is
// loaded where it is used).
type app struct {
	name, dir string
	conf      kv
	state     kv
}

// selectApp is `app "$1"`: the name is checked, the app must have an app.conf, and as root the
// skeleton of a half-deleted app directory comes back (an interrupted destroy, a hand cleanup:
// releases/ root 755, incoming/ the sudo user's 755).
func (c *Collector) selectApp(name string) (*app, error) {
	if !valid.App(name) {
		return nil, die("invalid app name")
	}
	d := c.appDir(name)
	if fi, err := os.Stat(filepath.Join(d, "app.conf")); err != nil || !fi.Mode().IsRegular() {
		if fi, err := os.Stat(d); err == nil && fi.IsDir() {
			return nil, die("the directory of " + name + " is incomplete (no app.conf): tando destroy -a " + name +
				" removes it, or tando up recreates it")
		}
		return nil, die("no such app: " + name)
	}
	if c.Env.EUID == 0 {
		c.skeleton(d)
	}
	return &app{name: name, dir: d, conf: loadKV(filepath.Join(d, "app.conf")), state: loadKV(filepath.Join(d, "state"))}, nil
}

// Skeleton is the repair `app` does as root for a valid app with an app.conf (for a caller that
// has the rest answered elsewhere).
func (c *Collector) Skeleton(name string) {
	if c.Env.EUID != 0 || !valid.App(name) {
		return
	}
	d := c.appDir(name)
	if fi, err := os.Stat(filepath.Join(d, "app.conf")); err == nil && fi.Mode().IsRegular() {
		c.skeleton(d)
	}
}

// skeleton recreates releases/ and incoming/ when they are missing. Failures are ignored, as the
// shell's install -d failures were (they only printed a message).
func (c *Collector) skeleton(d string) {
	mk := func(p string, uid int) {
		if fi, err := os.Stat(p); err == nil && fi.IsDir() {
			return
		}
		if err := os.Mkdir(p, 0o755); err != nil {
			return
		}
		os.Chmod(p, 0o755)
		os.Lchown(p, uid, 0)
	}
	mk(filepath.Join(d, "releases"), 0)
	uid := 0
	if c.SudoUser != "" {
		var ok bool
		if uid, ok = lookupUID(c.SudoUser); !ok {
			return // install -o <unknown user> fails without creating the directory
		}
	}
	mk(filepath.Join(d, "incoming"), uid)
}

// hostConf is $R/host.conf.
func (c *Collector) hostConf() kv { return loadKV(filepath.Join(c.Env.Root, "host.conf")) }

// executable is bash's [[ -x f ]] for root: a file with any execute bit (or a directory).
func executable(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && (fi.IsDir() || fi.Mode().Perm()&0o111 != 0)
}

// helperTimeout bounds a tando program status starts (log-stats reads journals: its first run
// after a minute can take a while on a big journal).
const helperTimeout = 120 * time.Second

func ctxOr(ctx context.Context) context.Context {
	if ctx == nil {
		return context.Background()
	}
	return ctx
}
