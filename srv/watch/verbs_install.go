package watch

import (
	"context"
	"os"
	"path/filepath"
	"time"

	"tando/srv/internal/atomicfile"
	"tando/srv/internal/decimal"
	"tando/srv/internal/fsinfo"
	"tando/srv/internal/out"
	"tando/srv/internal/run"
	"tando/srv/internal/systemd"
)

// The units. tandod (the daemon) runs the checks once a minute while tando-watch.timer is
// active; the timer itself starts tando-watch-fallback.service, which systemd skips while the
// daemon's socket exists, so a stopped or crash-looping daemon never means no checks. A manual
// `systemctl start tando-watch.service` (the agent after a rollback, the test suites) runs one
// check run now: through the daemon when it runs, else by itself. Each run begins with the
// metrics sample (tando-metrics sample, in-process in tandod) and, when an activation died or
// systemd gave up on an app, `tando-agent recover-all` in a unit of its own.
func oneshotUnit(self, desc, cond string) string {
	return `[Unit]
Description=` + desc + `
After=network.target caddy.service
StartLimitIntervalSec=0
` + cond + `
[Service]
Type=oneshot
# each run: the metrics sample (tando-metrics sample), recover-all when an activation died or an
# app is down, the checks; through tandod when it runs (tando-watch run asks it)
ExecStart=` + self + ` run
Nice=10
TimeoutStartSec=300
RuntimeDirectory=tando-watch
RuntimeDirectoryMode=0700
RuntimeDirectoryPreserve=yes
UMask=0022
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=yes
NoNewPrivileges=yes
MemoryMax=64M
LogLevelMax=notice
`
}

func serviceUnit(root, self string) string {
	return oneshotUnit(self, "tando: alert checks", "")
}

// fallbackUnit is what the timer starts: skipped (not failed) while /run/tandod/active exists,
// which tandod keeps only while its runs of the checks succeed (srv/daemon health.go): a panic,
// failed runs or runs it did not survive remove it, and so does systemd when tandod stops (it is
// in its RuntimeDirectory). A condition is one stat in systemd: no process per minute while
// tandod works, and the timer runs the checks within a minute when it does not.
func fallbackUnit(self string) string {
	return oneshotUnit(self, "tando: alert checks (when tandod does not run them)", "ConditionPathExists=!/run/tandod/active\n")
}

const timerUnit = `[Unit]
Description=tando: alert checks once a minute

[Timer]
OnCalendar=*-*-* *:*:00
AccuracySec=1s
Unit=tando-watch-fallback.service

[Install]
WantedBy=timers.target
`

// daemonUnit runs tandod. It writes only the state of the checks, the metrics and the log scan
// (and the audit log, through tando-logs, after restoring the firewall rules); the agent, which
// rewrites links, units and Caddy's config, runs outside it in units of its own (systemd-run).
func daemonUnit(root string) string {
	return `[Unit]
Description=tando: monitoring daemon (checks, metrics and the log scan once a minute)
After=network.target caddy.service
StartLimitIntervalSec=0

[Service]
Type=notify
NotifyAccess=main
ExecStartPre=+/bin/mkdir -p -m 0700 /run/tando-watch
ExecStart=` + root + `/bin/tandod
Restart=always
RestartSec=2
WatchdogSec=300
TimeoutStopSec=60
RuntimeDirectory=tandod
RuntimeDirectoryMode=0700
Environment=GOMAXPROCS=1 GOGC=50 GOMEMLIMIT=20MiB
Nice=5
CPUWeight=20
OOMScoreAdjust=-200
MemoryMax=64M
UMask=0022
ProtectSystem=strict
ReadWritePaths=/var/lib/tando -/run/tando-watch -/var/log/tando -/var/cache/tando-logs
ProtectHome=read-only
PrivateTmp=yes
NoNewPrivileges=yes
LogLevelMax=notice

[Install]
WantedBy=multi-user.target
`
}

func (w Watch) systemctl(ctx context.Context, args ...string) error {
	_, err := w.Env.Run.Output(ctx, run.Cmd{Argv: append([]string{"systemctl"}, args...), Env: cmdEnv, Timeout: 60 * time.Second})
	return err
}

// Install is the verb `install`: the timer units, the directories and the default settings
// file; the timer enabled. Alert details name apps and paths: state and history are root only
// (tando alerts uses sudo).
func (w Watch) Install(ctx context.Context, o *out.Writer) error {
	if err := needRoot(w.Env); err != nil {
		return err
	}
	for _, d := range []string{filepath.Dir(w.Dir), w.Dir} {
		os.MkdirAll(d, 0o755)
		os.Chmod(d, 0o755)
	}
	for _, d := range []string{w.Sec, filepath.Join(w.Dir, "out"), filepath.Join(w.Dir, "inbox")} {
		mkdir700(d)
	}
	for _, f := range []string{w.statePath(), w.historyPath()} {
		if fh, err := os.OpenFile(f, os.O_WRONLY|os.O_CREATE, 0o600); err == nil {
			fh.Close()
		}
		os.Chmod(f, 0o600)
	}
	if !fsinfo.ExistsNoFollow(w.Conf) {
		if err := atomicfile.Write(w.Conf, []byte(confHeader), atomicfile.Mode(0o644)); err != nil {
			return err
		}
	}
	units := []struct{ name, body string }{
		{"tando-watch.service", serviceUnit(w.Env.Root, w.Self)},
		{"tando-watch-fallback.service", fallbackUnit(w.Self)},
		{"tando-watch.timer", timerUnit},
	}
	daemon := isExec(w.bin("tandod"))
	if daemon {
		units = append(units, struct{ name, body string }{"tandod.service", daemonUnit(w.Env.Root)})
	}
	changed, daemonUnitChanged := false, false
	for _, u := range units {
		c, err := atomicfile.WriteIfChanged(filepath.Join(w.Units, u.name), []byte(u.body), atomicfile.Mode(0o644))
		if err != nil {
			return err
		}
		changed = changed || c
		daemonUnitChanged = daemonUnitChanged || (c && u.name == "tandod.service")
	}
	if changed {
		w.systemctl(ctx, "daemon-reload")
	}
	if err := w.systemctl(ctx, "enable", "-q", "--now", "tando-watch.timer"); err != nil {
		return errf("could not enable tando-watch.timer")
	}
	if daemon {
		w.systemctl(ctx, "enable", "-q", "tandod.service")
		if err := w.startDaemon(ctx, daemonUnitChanged); err != nil {
			return err
		}
	}
	o.KV("ok", "1")
	return nil
}

// Uninstall is the verb `uninstall`: the timer and its units go; settings, notifiers and state
// stay.
func (w Watch) Uninstall(ctx context.Context, o *out.Writer) error {
	if err := needRoot(w.Env); err != nil {
		return err
	}
	w.systemctl(ctx, "disable", "-q", "--now", "tando-watch.timer", "tandod.service")
	for _, u := range []string{"tando-watch.service", "tando-watch-fallback.service", "tando-watch.timer", "tandod.service"} {
		os.Remove(filepath.Join(w.Units, u))
	}
	w.systemctl(ctx, "daemon-reload")
	o.KV("ok", "1")
	return nil
}

// startDaemon makes the tandod that runs the one installed: started when it is not running,
// restarted (try-restart) when its unit changed or the binary it runs is not the file in
// /opt/tando/bin any more (host setup installed a new one), left alone otherwise. Then it checks
// that the process runs that very file. A restart, even in the middle of a tick, loses and repeats
// nothing: the tick is cancelled and the state is on disk (commit.go), and a stop asked for is no
// death (srv/daemon health.go).
func (w Watch) startDaemon(ctx context.Context, unitChanged bool) error {
	bin := w.bin("tandod")
	u, _ := systemd.Show(ctx, w.Env.Run, []string{"tandod.service"}, "ActiveState", "MainPID")
	var st, pid string
	if len(u) == 1 {
		st, pid = u[0]["ActiveState"], u[0]["MainPID"]
	}
	switch {
	case st != "active" && st != "activating" && st != "reloading":
		w.systemctl(ctx, "reset-failed", "tandod.service")
		if err := w.systemctl(ctx, "start", "tandod.service"); err != nil {
			return errf("could not start tandod.service")
		}
	case unitChanged || !runsFile(w.Env.Proc, pid, bin):
		if err := w.systemctl(ctx, "try-restart", "tandod.service"); err != nil {
			return errf("could not restart tandod.service")
		}
	default:
		return nil
	}
	for range 50 { // (Type=notify: started means ready; MainPID is there at once)
		if u, err := systemd.Show(ctx, w.Env.Run, []string{"tandod.service"}, "ActiveState", "MainPID"); err == nil &&
			u[0]["ActiveState"] == "active" && runsFile(w.Env.Proc, u[0]["MainPID"], bin) {
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return errf("tandod.service does not run %s after its restart: journalctl -u tandod", bin)
}

// runsFile: process pid runs the executable file path (the same inode; a file replaced since it
// started is another one).
func runsFile(proc, pid, path string) bool {
	if !decimal.IsDigits(pid) || pid == "0" {
		return false
	}
	a, err1 := os.Stat(filepath.Join(proc, pid, "exe"))
	b, err2 := os.Stat(path)
	return err1 == nil && err2 == nil && os.SameFile(a, b)
}
