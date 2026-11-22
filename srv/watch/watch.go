// Package watch is tando-watch: the alert checks of a tando host and the delivery of their
// notifications (docs/MONITORING.md). `run` is started once a minute by tando-watch.timer: one
// short process checks every app and the host, moves each (app, check) through ok -> pending ->
// firing -> resolved, and queues notifications. Nothing stays resident.
//
// How the package reads, top down:
//
//	tick.go          Run: one run, start to end (lock, facts, checks, decide, commit, deliver)
//	check.go         the Check interfaces and the order the checks run in
//	check_*.go       one file per check or family: caddy, oom, stuck, down, restarts, memory,
//	                 backup, disk (and the disk guard), health (+ liveness), tls, logscan (http,
//	                 slow, errors, logs, new errors), host (disk, inodes, memory, swap, load),
//	                 firewall, jobs (scheduled jobs that fail), postgres (the server, each
//	                 app's connections, the size of its database)
//	machine.go       the state machine of one (app, check): sample, flapping
//	reconcile.go     what to tell the notifiers: firing, resolved, reminders, silences
//	events.go        transitions: the history, the per-app incidents, the crash tail
//	commit.go        decide, record, send: how a killed run neither loses nor repeats a message
//	queue.go         the per-notifier queues in /var/lib/tando/watch/out/<name>/
//	notify*.go       Notifier: one implementation per type (webhook, slack, telegram, ntfy,
//	                 email); compose turns queued lines into one message
//	deliver.go       one attempt per notifier and run, in parallel, with backoff; the heartbeat
//	probe.go         HTTP: the health probes through Caddy, the direct liveness probe, certificates
//	facts.go         what the host says: /proc, statfs, cgroups, the app's activation lock
//	state.go         the durable and the volatile key=value stores
//	settings.go      alerts.conf over the defaults
//	verbs_*.go       the other verbs: show, history, brief, health, forget, set, notifier-add,
//	                 notifier-rm, heartbeat, silence, test, install, uninstall, doctor
//
// Files (modes and formats are the shell version's; a host upgraded from it keeps everything):
//
//	/opt/tando/alerts.conf            settings, key=value; "<app>.<key>" overrides per app (644)
//	/opt/tando/alerts.d/              notifier secrets and the heartbeat URL (root 700, files 600)
//	/var/lib/tando/watch/state        alert state, written atomically only on change (600)
//	/var/lib/tando/watch/history.tsv  one line per transition (600)
//	/var/lib/tando/watch/out/<name>/  queued messages per notifier (root 700; no secrets)
//	/var/lib/tando/watch/commit       a run's decided effects until they are all applied (600)
//	/run/tando-watch/                 volatile per-run data (tmpfs, root 700)
//
// Secrets are read only from root-only files and go into the HTTP request in this process:
// never into an argument, the journal, an error message or a world-readable file.
//
// The run is one function of a tick (the clock and the facts of one minute) over the stores:
// tandod (srv/daemon) calls it every minute in-process with a Cache of the key=value files; the
// one-shot `tando-watch run` (tando-watch.timer) is the fallback when tandod does not run.
//
// Layer: domain. It imports internal/* only; no other domain package, not daemon or daemon/proto:
// the log scan is a LogScanner and the metrics sample a func, which tandod fills with srv/logs and
// srv/metrics in-process.
package watch

import (
	"context"
	"path/filepath"
	"sync/atomic"
	"time"

	"tando/srv/internal/cost"
	"tando/srv/internal/env"
)

// Watch holds the paths and the outside world of tando-watch. Tests build one over a temp
// directory with a fixed clock, a run.Func and fake probes.
type Watch struct {
	Env     env.Env
	Conf    string        // /opt/tando/alerts.conf
	Sec     string        // /opt/tando/alerts.d
	Dir     string        // /var/lib/tando/watch
	RunDir  string        // /run/tando-watch
	Self    string        // /opt/tando/bin/tando-watch (its checksum is the `version` row of show)
	Units   string        // /etc/systemd/system
	Caddy   string        // /etc/caddy
	PID     int           // names this run's queue files (the shell's $$)
	Seq     *atomic.Int64 // with PID: every commit of a long-running process its own queue file
	Disks   []string      // the file systems tando writes to: /, /var, /opt/tando
	Backups string        // /var/backups/tando (the backup ping reads a backup's offsite state)
	PgData  string        // where PostgreSQL keeps the databases: /var/lib/postgresql

	Probe Prober     // health and liveness probes (HTTP through Caddy or to the app's port)
	Certs CertReader // the certificate Caddy serves for a site
	Send  Sender     // notifier deliveries and the heartbeat ping

	Scan   LogScanner                // the apps' logs: tando-logs watch-scan (tandod: in-process)
	Sample func(ctx context.Context) // the metrics sample before the checks (tandod: in-process)
	Cache  *Cache                    // what a long-running caller keeps between ticks (nil: none)
	Cost   *cost.Meter               // tandod's cost breakdown, by section (nil: none)
}

// New is the real machine under e.
func New(e env.Env, pid int) Watch {
	w := Watch{
		Env:     e,
		Conf:    filepath.Join(e.Root, "alerts.conf"),
		Sec:     filepath.Join(e.Root, "alerts.d"),
		Dir:     filepath.Join(e.Lib, "watch"),
		RunDir:  "/run/tando-watch",
		Self:    filepath.Join(e.Root, "bin", "tando-watch"),
		Units:   "/etc/systemd/system",
		Caddy:   "/etc/caddy",
		PID:     pid,
		Seq:     new(atomic.Int64),
		Disks:   []string{"/", "/var", e.Root},
		Backups: "/var/backups/tando",
		PgData:  "/var/lib/postgresql",
	}
	w.Probe = httpProber{header: filepath.Join(e.Root, "probe.header"), loopback: "127.0.0.1"}
	w.Certs = tlsCerts{loopback: "127.0.0.1"}
	w.Send = httpSender{}
	w.Scan = execScanner{bin: w.bin("tando-logs"), run: e.Run}
	w.Sample = w.ExecSample
	return w
}

func (w Watch) appDir(a string) string { return filepath.Join(w.Env.Root, "apps", a) }
func (w Watch) bin(name string) string { return filepath.Join(w.Env.Root, "bin", name) }
func (w Watch) statePath() string      { return filepath.Join(w.Dir, "state") }
func (w Watch) historyPath() string    { return filepath.Join(w.Dir, "history.tsv") }
func (w Watch) vstatePath() string     { return filepath.Join(w.RunDir, "vstate") }
func (w Watch) lockPath() string       { return filepath.Join(w.Dir, "lock") }
func (w Watch) now() int64             { return w.Env.Now().Unix() }

// cmdEnv is the environment of the programs tando-watch starts: systemd's PATH (caddy or nft
// may be in /usr/local) and the C locale, nothing inherited.
var cmdEnv = []string{"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL=C"}

// tandod's files that the one-shot side reads too: the mark that it runs the checks (in its own
// RuntimeDirectory, /run/tandod, removed whenever it stops; the fallback unit's condition), and
// its health (degraded since, why, the next retry) in /run/tando-watch, which outlives it: the
// "monitor" check reads it (srv/daemon health.go writes both).
const (
	DaemonActiveFile = "/run/tandod/active"
	DaemonStateFile  = "/run/tando-watch/tandod.health"
)

// TickTimeout bounds one run of the checks, in tandod and in the one-shot alike (its commands
// have shorter limits of their own; this catches the sum). The chain: a tick 240 s < tandod's
// socket allows a tick 250 s < the client waits 260 s < the units' TimeoutStartSec and tandod's
// WatchdogSec, 300 s.
const TickTimeout = 240 * time.Second

func needRoot(e env.Env) error {
	if e.EUID != 0 {
		return errf("this needs root (sudo)")
	}
	return nil
}
