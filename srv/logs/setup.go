package logs

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"math/big"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"tando/srv/internal/apps"
	"tando/srv/internal/atomicfile"
	"tando/srv/internal/kvfile"
	"tando/srv/internal/out"
	"tando/srv/internal/run"
	"tando/srv/internal/valid"
)

// HostSetup (host-setup [key=value ...]) stores host defaults in logs.conf, creates the log
// directories, caps the main journal, and sets up every app's journal and request log.
func (l *Logs) HostSetup(ctx context.Context, args []string, w *out.Writer) error {
	if err := l.needRoot(); err != nil {
		return err
	}
	h := l.loadHost()
	for _, kv := range args {
		k, v, ok := strings.Cut(kv, "=")
		if !ok || !Valid(k, v) {
			return fmt.Errorf("bad log setting: %s", kv)
		}
		h[k] = norm(v)
	}
	if _, err := kvfile.Save(l.hostConf(), h, l.rootPerm(0o644)); err != nil {
		return err
	}
	ru, rg := l.root()
	if err := ensureDir(l.P.LogDir, 0o755, ru, rg); err != nil {
		return err
	}
	if err := ensureDir(l.P.Cache, 0o700, ru, rg); err != nil {
		return err
	}
	if err := l.createAudit(); err != nil {
		return err
	}
	// the main journal (system services, activations, Caddy) gets a fixed cap too
	dropin := filepath.Join(l.P.Systemd, "journald.conf.d")
	if err := ensureDir(dropin, 0o755, -1, -1); err != nil {
		return err
	}
	conf := "# written by tando-logs: cap of the main journal (apps log into their own namespaces)\n" +
		"[Journal]\nSystemMaxUse=" + hostSetting(h, "journal_max") + "\nRuntimeMaxUse=64M\n"
	changed, err := atomicfile.WriteIfChanged(filepath.Join(dropin, "tando.conf"), []byte(conf), l.rootPerm(0o644))
	if err != nil {
		return err
	}
	if changed {
		l.systemctl(ctx, "restart", "systemd-journald")
	}
	names, _ := apps.Names(l.Env.Root)
	for _, n := range names {
		a, err := l.app(n)
		if err == nil {
			err = a.setup(ctx)
		}
		if err != nil {
			l.warn("warning=log setup of %s failed", n)
		}
	}
	w.KV("ok", "1")
	return nil
}

// createAudit: the audit log exists, root:adm 0640, before anything appends to it.
func (l *Logs) createAudit() error {
	gid, err := l.Users.GID("adm")
	if err != nil {
		gid = -1
	}
	uid, _ := l.root()
	return createFile(l.auditFile(), 0o640, uid, gid)
}

func (l *Logs) systemctl(ctx context.Context, args ...string) error {
	_, err := l.Env.Run.Output(ctx, run.Cmd{Argv: append([]string{"systemctl"}, args...)})
	return err
}

// AppSetup (app-setup <app>), called by the agent's configure.
func (l *Logs) AppSetup(ctx context.Context, name string, w *out.Writer) error {
	if err := l.needRoot(); err != nil {
		return err
	}
	a, err := l.app(name)
	if err != nil {
		return err
	}
	if err := a.setup(ctx); err != nil {
		return err
	}
	w.KV("ok", "1")
	return nil
}

// setup writes the app's journald namespace config and prepares its request log directory.
func (a *app) setup(ctx context.Context) error {
	maxUse, keep, rate := a.setting("log_max"), a.setting("log_keep"), a.setting("log_rate")
	// retention removes whole journal files: a file is closed after MaxFileSec, so it must be
	// short against log_keep or a 1h retention would keep a day. A quarter of log_keep, 15 min
	// to 1 day
	kh := keepHours(keep)
	fmin := min(max(kh*15, 15), 1440)
	var b strings.Builder
	fmt.Fprintf(&b, "# written by tando-logs for app %s: its own journal, capped (tando.conf log_max, log_keep)\n", a.name)
	b.WriteString("# circular: when the files reach SystemMaxUse, journald deletes the oldest to make room\n")
	fmt.Fprintf(&b, "[Journal]\nStorage=persistent\nSystemMaxUse=%s\nRuntimeMaxUse=8M\nMaxRetentionSec=%dh\nMaxFileSec=%dmin\nCompress=yes\n",
		maxUse, kh, fmin)
	// per service in this namespace: the app, its pre-flight and its jobs. (A unit's own
	// LogRateLimitIntervalSec=0 would mean "journald's default", not "off".)
	if rate == "off" {
		b.WriteString("RateLimitIntervalSec=0\n")
	} else {
		burst, interval, _ := strings.Cut(rate, "/")
		fmt.Fprintf(&b, "RateLimitIntervalSec=%s\nRateLimitBurst=%s\n", interval, burst)
	}
	changed, err := atomicfile.WriteIfChanged(a.nsConf(), []byte(b.String()), a.l.rootPerm(0o644))
	if err != nil {
		return err
	}
	if changed {
		a.applyJournal(ctx, maxUse, kh)
	}
	caddy, err1 := a.l.Users.UID("caddy")
	grp, err2 := a.l.Users.GID("tando-" + a.name)
	if u := a.conf["user"]; err2 != nil && u != "" { // an adopted app keeps its own user and group
		grp, err2 = a.l.Users.GID(u)
	}
	if err1 != nil || err2 != nil {
		return nil
	}
	ru, rg := a.l.root()
	if err := ensureDir(a.l.P.LogDir, 0o755, ru, rg); err != nil {
		return err
	}
	// Caddy writes, the app's group reads; the setgid bit gives rolled files the same group
	dir := a.logDir()
	if err := ensureDir(dir, 0o750|os.ModeSetgid, caddy, grp); err != nil {
		return err
	}
	ents, _ := os.ReadDir(dir)
	for _, e := range ents {
		n := e.Name()
		if m1, _ := filepath.Match("access*.log", n); !m1 {
			if m2, _ := filepath.Match("access*.log.gz", n); !m2 {
				continue
			}
		}
		if e.Type()&os.ModeSymlink != 0 {
			continue
		}
		ownFile(filepath.Join(dir, n), 0o640, caddy, grp)
	}
	// created here: `caddy validate` (as root) would otherwise create it root-owned
	return createFile(filepath.Join(dir, "access.log"), 0o640, caddy, grp)
}

// applyJournal: a changed namespace config takes effect when that journald instance restarts.
// The app keeps running and keeps its stdout/stderr: journald hands its stream sockets to
// systemd's file descriptor store (FileDescriptorStoreMax in systemd-journald@.service) and takes
// them back, so no line is lost (measured: 13 of 13 once-a-second lines across two restarts).
// Then the limits are applied now instead of at the next file rotation: vacuum to the size cap
// and retention.
func (a *app) applyJournal(ctx context.Context, maxUse string, keepH int64) {
	unit := "systemd-journald@" + a.ns() + ".service"
	if a.l.systemctl(ctx, "-q", "is-active", unit) != nil {
		return
	}
	if a.l.systemctl(ctx, "restart", unit) != nil {
		return
	}
	r := a.l.Env.Run
	r.Output(ctx, run.Cmd{Argv: []string{"journalctl", "-q", "--namespace=" + a.ns(), "--rotate"}})
	r.Output(ctx, run.Cmd{Argv: []string{"journalctl", "-q", "--namespace=" + a.ns(), "--vacuum-size=" + maxUse,
		"--vacuum-time=" + strconv.FormatInt(keepH, 10) + "h"}})
}

// AppRemove (app-remove <app>) removes the app's journal namespace, request logs and caches.
// The app.conf may already be gone.
func (l *Logs) AppRemove(ctx context.Context, name string, w *out.Writer) error {
	if err := l.needRoot(); err != nil {
		return err
	}
	if !valid.App(name) {
		return errors.New("invalid app name")
	}
	a := &app{l: l, name: name}
	ns := a.ns()
	l.systemctl(ctx, "stop", "systemd-journald@"+ns+".service", "systemd-journald@"+ns+".socket",
		"systemd-journald-varlink@"+ns+".socket", "systemd-journald@"+ns+"-varlink.socket")
	os.Remove(a.nsConf())
	if id := l.machineID(); id != "" {
		os.RemoveAll(filepath.Join(l.P.Journal, id+"."+ns))
		os.RemoveAll(filepath.Join(l.P.RunJournal, id+"."+ns))
	}
	os.RemoveAll(a.logDir())
	os.RemoveAll(a.scanDir()) // (groups, positions, the request index: an app made again starts afresh)
	if l.Cache != nil {
		l.Cache.forget(name)
	}
	os.Remove(filepath.Join(l.P.Cache, name+".stats"))
	os.Remove(filepath.Join(l.P.Cache, name+".reqlog"))
	w.KV("removed", "1")
	return nil
}

// UnitProps (unit-props <app>): the unit properties of the app unit, its pre-flight and its
// jobs; the size cap and the rate limit live in the namespace's config.
func (l *Logs) UnitProps(name string, w io.Writer) error {
	a, err := l.app(name)
	if err != nil {
		return err
	}
	_, err = io.WriteString(w, "LogNamespace="+a.ns()+"\n")
	return err
}

var (
	reProbe    = regexp.MustCompile(`(?m)^X-Tando-Probe: ([0-9a-f]{32,64})$`)
	reCaddyVer = regexp.MustCompile(`^([0-9]+)\.([0-9]+)`)
)

// CaddyLog (caddy-log <app>) prints the log block of the app's Caddy site (tab-indented for the
// site block), nothing when access_log is off.
func (l *Logs) CaddyLog(ctx context.Context, name string, w io.Writer) error {
	a, err := l.app(name)
	if err != nil {
		return err
	}
	if a.setting("access_log") != "on" {
		return nil
	}
	keepFor := keepHours(a.setting("access_keep_for"))
	r := a.roll()
	file := a.reqPath(fmt.Sprintf("%d %d %d", r.Size, r.Keep, keepFor))
	// `output file { mode }` exists from Caddy 2.8; older ones keep the mode of the file we create
	mode := ""
	if v, err := l.Env.Run.Output(ctx, run.Cmd{Argv: []string{"caddy", "version"}}); err == nil {
		cv := strings.TrimPrefix(strings.TrimSpace(string(v)), "v")
		cv, _, _ = strings.Cut(cv, " ")
		if m := reCaddyVer.FindStringSubmatch(cv); m != nil {
			maj, _ := strconv.Atoi(m[1])
			minor, _ := strconv.Atoi(m[2])
			if maj > 2 || minor >= 8 {
				mode = "\n\t\t\tmode 0640"
			}
		}
	}
	// the secret of tando's own health checks; a random never-sent value until it exists
	probe := ""
	if b, err := os.ReadFile(filepath.Join(l.Env.Root, "probe.header")); err == nil {
		if m := reProbe.FindSubmatch(b); m != nil {
			probe = string(m[1])
		}
	}
	if probe == "" {
		n, _ := rand.Int(rand.Reader, big.NewInt(1e10))
		probe = "none-" + n.String()
	}
	_, err = fmt.Fprintf(w, `	# tando's own health checks (from this host, with the root-only secret header of
	# /opt/tando/probe.header) stay out of the request log and its statistics
	@tandoprobe {
		header X-Tando-Probe %s
		remote_ip 127.0.0.1 ::1
	}
	skip_log @tandoprobe
	log {
		output file %s {%s
			roll_size %dMiB
			roll_keep %d
			roll_keep_for %dh
		}
		format filter {
			wrap json
			fields {
				request>headers delete
				request>tls delete
				resp_headers delete
				user_id delete
				request>uri regexp \?.*$ ?-
			}
		}
	}
`, probe, file, mode, r.Size, r.Keep, keepFor)
	return err
}

// reqPath is the file name Caddy gets. Caddy keeps one log writer per file name across config
// reloads, so a changed roll_size/roll_keep would wait for a restart of Caddy (every site's
// connections). The name alternates between dir/access.log and dir/./access.log (the same file)
// whenever the rotation changes: the reload then opens a new writer with the new rotation, no
// restart. /var/cache/tando-logs/<app>.reqlog remembers "<0|1> <size>,<keep>,<keep_for>".
func (a *app) reqPath(rot string) string {
	want := strings.ReplaceAll(rot, " ", ",")
	f := filepath.Join(a.l.P.Cache, a.name+".reqlog")
	// no record (an app from before this, whose site Caddy may run with other values): "./"
	v, cur := "1", ""
	if b, err := os.ReadFile(f); err == nil {
		line, _, _ := strings.Cut(string(b), "\n")
		fs := strings.Fields(line)
		if len(fs) > 0 {
			v = fs[0]
		}
		if len(fs) > 1 {
			cur = strings.Join(fs[1:], " ")
		}
	}
	dot := v != "0"
	if cur != "" && cur != want {
		dot = !dot
	}
	if cur != want && a.l.Env.EUID == 0 {
		n := "0"
		if dot {
			n = "1"
		}
		if ensureDir(a.l.P.Cache, 0o700, -1, -1) == nil {
			atomicfile.Write(f, []byte(n+" "+want+"\n"), atomicfile.Mode(0o644))
		}
	}
	if dot {
		return a.logDir() + "/./access.log"
	}
	return a.logDir() + "/access.log"
}

// CheckValue (valid <key> <value>): exit 1 when the value is not a valid log setting.
func CheckValue(k, v string) error {
	if !Valid(k, v) {
		if k == "" {
			k = "?"
		}
		return fmt.Errorf("bad value for %s: %s", k, v)
	}
	return nil
}
