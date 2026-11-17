// Package logs is the logging side of tando on the server (tando-logs, docs/LOGGING.md). Nothing
// keeps running between calls; tando-agent calls it, and tando-watch runs watch-scan once a
// minute.
//
//	per-app journal  each app unit logs into its own journald namespace "tando-<app>" with its own
//	                 size cap and retention (/etc/systemd/journald@tando-<app>.conf), so a noisy app
//	                 can only evict its own lines. A per-unit rate limit bounds floods.
//	request log      Caddy writes JSON lines to /var/log/tando/<app>/access.log (caddy:tando-<app>
//	                 0640 in a 2750 directory), rotated by Caddy itself by size. Request headers,
//	                 response headers, TLS details and query strings are never written.
//	audit trail      /var/log/tando/audit.log, one tab-separated line per mutating agent verb.
//
// Files of this package (one concern each):
//
//	logs.go      Logs, its paths, the app being worked on
//	settings.go  log settings: checks, defaults, the request log's rotation
//	setup.go     host-setup, app-setup, app-remove, unit-props, caddy-log, valid
//	query.go     logs: the spec, journalctl's argv, the journal filter (package journal)
//	history.go   history.tsv: when each release was live
//	stats.go     log-stats: disk use and per-hour counts, cached
//	requests.go  req-summary, req-tail, req-errors over the request log files (package reqlog)
//	scan.go      watch-scan and errors: incremental error and request scan (package errscan)
//	audit.go     audit-write, audit-read, audit-origin
//	doctor.go    log-doctor
//	fs.go        what the shell did with install -d, du, df, chown
//	stream.go    a command's output read line by line, stopped early when enough was read
//
// Output: key=value lines or tab-separated rows whose first field names the row type (out), or
// for logs and caddy-log text lines. Every argv is built here; text from the client (a grep
// pattern, a cursor) is read from stdin, checked against a whitelist and used as data, never
// handed to a shell.
//
// Layer: domain. It imports its parsers (logs/lines, logs/journal, logs/reqlog, logs/errscan) and
// internal/*; no other domain package, not daemon. The parsers import nothing of logs and no files
// or commands.
package logs

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"tando/srv/internal/apps"
	"tando/srv/internal/env"
	"tando/srv/internal/kvfile"
	"tando/srv/internal/valid"
)

// Paths are the places outside Env's that tando-logs reads and writes (tests use a temp dir).
type Paths struct {
	LogDir     string // /var/log/tando: <app>/access.log, audit.log
	VarLog     string // /var/log: the file system the journals share (df)
	Cache      string // /var/cache/tando-logs: <app>.stats, <app>.reqlog (root 700)
	Systemd    string // /etc/systemd: journald@tando-<app>.conf, journald.conf.d/tando.conf
	Journal    string // /var/log/journal: <machine-id>.tando-<app>/
	RunJournal string // /run/log/journal
	MachineID  string // /etc/machine-id
}

// defaultPaths are the server's.
func defaultPaths() Paths {
	return Paths{LogDir: "/var/log/tando", VarLog: "/var/log", Cache: "/var/cache/tando-logs", Systemd: "/etc/systemd",
		Journal: "/var/log/journal", RunJournal: "/run/log/journal", MachineID: "/etc/machine-id"}
}

// Logs carries what every verb needs.
type Logs struct {
	Env    env.Env
	P      Paths
	Stderr io.Writer           // warnings and per-app errors of verbs that go on (the shell's subshells)
	Getenv func(string) string // SUDO_USER, TANDO_AUDIT_WHO, TANDO_AUDIT_FROM; set by main (nil: none)
	PPID   int                 // where audit-origin starts looking for the ssh session; set by main
	// LimitCPU bounds the CPU seconds of this process and the commands it starts (a query,
	// except -f; the shell's ulimit -t 120). nil: no limit (tests).
	LimitCPU func(seconds uint64) error
	Users    Users // user and group ids (caddy, tando-<app>, adm)
	// Trim is called after a request index roll that read something, before a verb goes on to
	// read the index: main returns the roll's memory to the system there (a verb's peak is then
	// the larger of the two, not their sum). nil: nothing (a long-running caller decides itself).
	Trim func()
	// Cache, when set, is kept by a long-running caller between its calls (ScanCache); nil: each
	// call starts from the files.
	Cache *ScanCache
}

// New is Logs on the real machine's paths.
func New(e env.Env) *Logs {
	return &Logs{Env: e, P: defaultPaths(), Stderr: os.Stderr, Users: OSUsers{}}
}

func (l *Logs) hostConf() string  { return filepath.Join(l.Env.Root, "logs.conf") }
func (l *Logs) auditFile() string { return filepath.Join(l.P.LogDir, "audit.log") }
func (l *Logs) scanDir() string   { return filepath.Join(l.Env.Lib, "logscan") }

// errNotRoot is the shell's need_root.
var errNotRoot = errors.New("this needs root (sudo)")

func (l *Logs) needRoot() error {
	if l.Env.EUID != 0 {
		return errNotRoot
	}
	return nil
}

func (l *Logs) warn(format string, a ...any) {
	if l.Stderr != nil {
		fmt.Fprintf(l.Stderr, format+"\n", a...)
	}
}

// app is the app a verb works on: its name, its app.conf and the host defaults (logs.conf).
type app struct {
	l    *Logs
	name string
	conf map[string]string
	host map[string]string
	sc   *ScanCache // the caller's cache (or a fresh one) and this app's part of it
	as   *appScan
}

// cached: the app's part of the caller's cache, a fresh one when there is none.
func (a *app) cached() (*ScanCache, *appScan) {
	if a.as == nil {
		a.sc = a.l.Cache
		if a.sc == nil {
			a.sc = NewScanCache()
		}
		a.as = a.sc.app(a.l, a.name)
	}
	return a.sc, a.as
}

// app checks the name and loads the app's settings. An unreadable file reads as empty, as in the
// shell version (`[[ -r $f ]] || return 0`).
func (l *Logs) app(name string) (*app, error) {
	if !valid.App(name) {
		return nil, errors.New("invalid app name")
	}
	fi, err := os.Stat(filepath.Join(apps.Dir(l.Env.Root, name), "app.conf"))
	if err != nil || !fi.Mode().IsRegular() {
		return nil, fmt.Errorf("no such app: %s", name)
	}
	conf, _ := apps.Conf(l.Env.Root, name)
	return &app{l: l, name: name, conf: orEmpty(conf), host: l.loadHost()}, nil
}

func (l *Logs) loadHost() map[string]string {
	h, _ := kvfile.Load(l.hostConf())
	return orEmpty(h)
}

func orEmpty(m map[string]string) map[string]string {
	if m == nil {
		return map[string]string{}
	}
	return m
}

func (a *app) ns() string     { return "tando-" + a.name }
func (a *app) nsConf() string { return filepath.Join(a.l.P.Systemd, "journald@tando-"+a.name+".conf") }
func (a *app) dir() string    { return apps.Dir(a.l.Env.Root, a.name) }
func (a *app) logDir() string { return filepath.Join(a.l.P.LogDir, a.name) }

// nsDir is the namespace's journal directory, "" when the machine id is unreadable.
func (a *app) nsDir() string {
	id := a.l.machineID()
	if id == "" {
		return ""
	}
	return filepath.Join(a.l.P.Journal, id+"."+a.ns())
}

// machineID: /etc/machine-id, only when it is 32 hex digits (it becomes part of a path that is
// removed recursively).
func (l *Logs) machineID() string {
	b, err := os.ReadFile(l.P.MachineID)
	if err != nil {
		return ""
	}
	id := string(b)
	for len(id) > 0 && (id[len(id)-1] == '\n' || id[len(id)-1] == '\r') {
		id = id[:len(id)-1]
	}
	if len(id) != 32 {
		return ""
	}
	for i := 0; i < len(id); i++ {
		if c := id[i]; !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return ""
		}
	}
	return id
}
