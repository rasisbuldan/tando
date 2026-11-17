package offsite

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"tando/srv/internal/atomicfile"
	"tando/srv/internal/lock"
	"tando/srv/internal/out"
	"tando/srv/internal/run"
)

// Sync is the timer's run (the verb `sync`, every 30 minutes): it checks the credentials, uploads
// every backup still waiting (pending, failed and due again, or killed mid-way), applies the
// offsite retention, and refreshes the inventory once a day. A push started by the agent that
// holds an app's lock is left alone.
//
// now: also the failed ones whose next attempt is not due yet (`tando backup offsite sync`).
func (o Offsite) Sync(ctx context.Context, w *out.Writer, now bool) error {
	if err := o.needRoot(); err != nil {
		return err
	}
	s, err := o.open()
	if errors.Is(err, errOff) {
		for _, a := range o.backupApps() {
			o.refreshBrief(a, nil)
		}
		w.KV("skipped", "offsite off")
		return nil
	}
	if err != nil {
		return err
	}
	o.ensureDirs()
	cctx, cancel := context.WithTimeout(ctx, time.Minute)
	_, cerr := s.cli.listOne(cctx, s.hostPrefix(), "", "", 1)
	cancel()
	if cerr == nil {
		o.credsResult(nil)
	} else if ce := credsErrOnly(cerr); ce != nil {
		o.credsResult(ce)
	}
	hs := o.loadHostState()
	hs["skew"] = strconv.FormatInt(int64(s.cli.skew/time.Second), 10)
	o.saveHostState(hs)
	var uploaded, failed, deleted int
	apps := map[string]bool{}
	for _, a := range o.backupApps() {
		apps[a] = true
	}
	for _, a := range o.appNames() {
		apps[a] = true
	}
	for a := range apps {
		u, f := o.syncApp(ctx, s, a, now)
		uploaded += u
		failed += f
	}
	if cerr == nil {
		if absDur(s.cli.skew) > 5*time.Minute {
			w.KV("retention", "skipped: this server's clock is "+absDur(s.cli.skew).Round(time.Second).String()+" off the storage's")
		} else {
			deleted = o.retention(ctx, s, apps)
		}
		if o.now()-num(hs["inventory"]) > 20*3600 {
			if err := o.putInventory(ctx, s); err == nil {
				hs = o.loadHostState()
				hs["inventory"] = strconv.FormatInt(o.now(), 10)
				o.saveHostState(hs)
			} else {
				w.KV("inventory_error", err.Error())
			}
		}
	}
	for a := range apps {
		o.refreshBrief(a, &s.conf)
	}
	w.KV("uploaded", strconv.Itoa(uploaded))
	w.KV("failed", strconv.Itoa(failed))
	w.KV("deleted", strconv.Itoa(deleted))
	if cerr != nil {
		return cerr
	}
	return nil
}

// syncApp pushes the app's waiting backups, newest first
func (o Offsite) syncApp(ctx context.Context, s *session, app string, now bool) (int, int) {
	l, err := lock.Acquire(filepath.Join(o.Dir, "locks", app+".lock"), time.Second)
	if err != nil {
		return 0, 0 // (an upload of this app runs now)
	}
	defer l.Release()
	var up, fail int
	for _, b := range o.localBackups(app) {
		if b.state["state"] == "uploaded" || !wanted(b, s.conf.Since) {
			continue
		}
		if b.state["state"] == "failed" && num(b.state["next_try"]) > o.now() && !now {
			continue
		}
		if err := o.pushLocked(ctx, s, app, b.id); err != nil {
			fail++
			if credsErrOnly(err) != nil || ctx.Err() != nil {
				break // (the others would fail the same way)
			}
			continue
		}
		up++
	}
	return up, fail
}

// retention deletes, per app, what prune says; only under this server's host id
func (o Offsite) retention(ctx context.Context, s *session, local map[string]bool) int {
	apps := map[string]bool{}
	for a := range local {
		apps[a] = true
	}
	if lp, err := s.cli.list(ctx, s.hostPrefix(), "/", 20); err == nil {
		for _, p := range lp.Prefixes {
			a := strings.TrimSuffix(strings.TrimPrefix(p, s.hostPrefix()), "/")
			if checkApp(a) == nil {
				apps[a] = true
			}
		}
	}
	n := 0
	for a := range apps {
		rb, err := o.remoteBackups(ctx, s, s.hostID, a)
		if err != nil || len(rb) <= s.conf.Keep.Min {
			continue
		}
		for _, id := range prune(rb, s.conf.Keep) {
			if err := s.cli.del(ctx, s.key(s.hostID, a, id+".rbk")); err != nil {
				break
			}
			s.cli.del(ctx, s.key(s.hostID, a, id+".manifest"))
			n++
		}
	}
	return n
}

// ---- the timer -------------------------------------------------------------------------------

func (o Offsite) unitService() string {
	return `[Unit]
Description=tando: offsite backups (uploads waiting or failed, retention, inventory)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=` + o.bin("tando-offsite") + ` sync
Nice=10
IOSchedulingClass=idle
UMask=0077
ProtectSystem=strict
ReadWritePaths=` + o.Dir + ` ` + o.Backups + `
ProtectHome=yes
PrivateTmp=yes
NoNewPrivileges=yes
MemoryMax=256M
`
}

const unitTimer = `[Unit]
Description=tando: offsite backups every 30 minutes

[Timer]
OnCalendar=*:00/30
RandomizedDelaySec=300
Persistent=true

[Install]
WantedBy=timers.target
`

func (o Offsite) systemctl(ctx context.Context, args ...string) error {
	_, err := o.Env.Run.Output(ctx, run.Cmd{Argv: append([]string{"systemctl"}, args...), Timeout: time.Minute})
	return err
}

func (o Offsite) installUnits(ctx context.Context) error {
	c1, err := atomicfile.WriteIfChanged(filepath.Join(o.Units, "tando-offsite.service"), []byte(o.unitService()), modeOf(0o644))
	if err != nil {
		return err
	}
	c2, err := atomicfile.WriteIfChanged(filepath.Join(o.Units, "tando-offsite.timer"), []byte(unitTimer), modeOf(0o644))
	if err != nil {
		return err
	}
	if c1 || c2 {
		if err := o.systemctl(ctx, "daemon-reload"); err != nil {
			return err
		}
	}
	return o.systemctl(ctx, "enable", "--now", "tando-offsite.timer")
}

func (o Offsite) removeUnits(ctx context.Context) {
	o.systemctl(ctx, "disable", "--now", "tando-offsite.timer")
	os.Remove(filepath.Join(o.Units, "tando-offsite.timer"))
	os.Remove(filepath.Join(o.Units, "tando-offsite.service"))
	o.systemctl(ctx, "daemon-reload")
}

// kick starts a sync now, in the timer's unit (not waited for)
func (o Offsite) kick(ctx context.Context) {
	o.systemctl(ctx, "start", "--no-block", "tando-offsite.service")
}
