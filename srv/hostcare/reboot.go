package hostcare

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"tando/srv/internal/kvfile"
	"tando/srv/internal/valid"
)

// RebootInput is everything the reboot decision depends on: no files, no clock of its own.
type RebootInput struct {
	Now                    time.Time
	Loc                    *time.Location // the window's time zone
	WindowStart, WindowEnd int            // minutes after midnight in Loc; end < start: across midnight
	Manual                 bool           // the owner asked (tando host reboot); else the care timer
	NowFlag                bool           // --now: not waiting for the window (manual only)
	Enabled                bool           // care_reboot=on (automatic only)
	Required               bool           // /run/reboot-required exists (automatic only)
	Skip                   bool           // tando host care skip: the next automatic one is skipped
	Uptime                 time.Duration  // since the last boot
	Busy                   []string       // what holds the server: a deploy, an upload, a setup
	StaleBackups           []string       // apps whose last backup is older than backup_hours
	Proven                 bool           // a reboot by tando came back healthy, or the owner confirmed
	CaddyOurs              bool           // Caddy serves only tando's sites
	OtherSitesOK           bool           // the owner allowed reboots with other sites (--even-with-other-sites)
}

// RebootDecision says what to do now.
type RebootDecision struct {
	Go          bool      // reboot (after the notice's lead time)
	Wait        bool      // not now, but within this window or the next one it may
	At          time.Time // Wait: when to look again (the window's start, or in 15 minutes)
	BackupFirst []string  // take these backups before the reboot
	Reason      string    // why not, in a sentence the owner reads
}

// InWindow: the wall-clock time of t in loc is inside [start, end) (minutes after midnight). A
// window across midnight (23:00-01:00) is in when after start or before end. On a day whose
// clock skips the window (daylight saving time starts inside it), there is no window that day.
func InWindow(t time.Time, loc *time.Location, start, end int) bool {
	l := t.In(loc)
	m := l.Hour()*60 + l.Minute()
	if start < end {
		return m >= start && m < end
	}
	return m >= start || m < end
}

// NextWindow is the next start of the window after t (in loc), at most 8 days ahead.
func NextWindow(t time.Time, loc *time.Location, start int) time.Time {
	l := t.In(loc)
	for d := 0; d < 8; d++ {
		c := time.Date(l.Year(), l.Month(), l.Day()+d, start/60, start%60, 0, 0, loc)
		// a skipped wall-clock time is normalised forward by time.Date: keep only real ones
		if c.After(t) && c.In(loc).Hour()*60+c.In(loc).Minute() == start {
			return c
		}
	}
	return t.Add(24 * time.Hour)
}

// DecideReboot is the reboot rule, as one pure function (tested as a table with a fake clock):
//
//   - automatic reboots only with care_reboot on, only when one is needed, not when skipped once,
//     not within a day of the last boot (no reboot loops), and the first one only after a reboot
//     by tando came back healthy or the owner confirmed (tando host care on --reboot asks);
//   - never while Caddy serves sites tando does not manage, unless the owner allowed it;
//   - only inside the window (a manual reboot with --now: at once);
//   - never while a deploy, an upload or a setup holds the server (automatic: tried again in 15
//     minutes while the window lasts; manual: refused, saying what holds it);
//   - stale backups are taken first.
func DecideReboot(in RebootInput) RebootDecision {
	switch {
	case !in.Manual && !in.Enabled:
		return RebootDecision{Reason: "automatic reboots are off (tando host care on --reboot)"}
	case !in.Manual && !in.Required:
		return RebootDecision{Reason: "no reboot is needed"}
	case !in.CaddyOurs && !in.OtherSitesOK:
		return RebootDecision{Reason: "Caddy on this server also serves sites tando does not manage: a reboot takes them down too, so tando does not reboot it on its own (tando host care on --reboot --even-with-other-sites allows it)"}
	case !in.Manual && !in.Proven:
		return RebootDecision{Reason: "the first reboot is yours: tando host reboot (afterwards care reboots on its own)"}
	case !in.Manual && in.Skip:
		return RebootDecision{Reason: "skipped once (tando host care skip)"}
	case !in.Manual && in.Uptime < 24*time.Hour:
		return RebootDecision{Reason: "the server started less than a day ago: no second reboot so soon"}
	}
	if !(in.Manual && in.NowFlag) && !InWindow(in.Now, in.Loc, in.WindowStart, in.WindowEnd) {
		return RebootDecision{Wait: true, At: NextWindow(in.Now, in.Loc, in.WindowStart), Reason: "outside the maintenance window"}
	}
	if len(in.Busy) > 0 {
		d := RebootDecision{Reason: "not now: " + strings.Join(in.Busy, ", ")}
		if !in.Manual {
			d.Wait, d.At = true, in.Now.Add(15*time.Minute)
			if !InWindow(d.At, in.Loc, in.WindowStart, in.WindowEnd) {
				d.At = NextWindow(in.Now, in.Loc, in.WindowStart)
			}
		}
		return d
	}
	return RebootDecision{Go: true, BackupFirst: in.StaleBackups}
}

// busy: what holds the server: an app whose activation is not idle or whose lock is held (a
// deploy, a backup, an env change), an upload lease, tando's host-wide locks (setup, install).
func (h *Host) busy() []string {
	var res []string
	held := func(p string) bool {
		f, err := os.OpenFile(p, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
		if err != nil {
			return false
		}
		defer f.Close()
		if err := syscall.Flock(int(f.Fd()), syscall.LOCK_SH|syscall.LOCK_NB); err != nil {
			return errors.Is(err, syscall.EWOULDBLOCK)
		}
		syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		return false
	}
	ents, _ := os.ReadDir(filepath.Join(h.Env.Root, "apps"))
	for _, e := range ents {
		a := e.Name()
		if !valid.App(a) {
			continue
		}
		d := filepath.Join(h.Env.Root, "apps", a)
		st, _ := kvfile.Load(filepath.Join(d, "state"))
		up, _ := kvfile.Load(filepath.Join(d, "upload"))
		switch {
		case st["phase"] != "" && st["phase"] != "idle":
			res = append(res, "a deploy of "+a+" is in phase "+clean(st["phase"], 20))
		case held(filepath.Join(d, "lock")):
			res = append(res, "something holds "+a+" (a deploy, backup or change; tando status "+a+")")
		case up["token"] != "" && h.now()-num(up["started"]) < 900:
			res = append(res, "an upload of "+a+" is running")
		}
	}
	for _, l := range []struct{ f, what string }{{".host.lock", "a host setup is running"}, {".install.lock", "an install of tando is running"}} {
		if held(filepath.Join(h.Env.Root, l.f)) {
			res = append(res, l.what)
		}
	}
	return res
}

func num(s string) int64 {
	var n int64
	for i := 0; i < len(s) && i < 18; i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0
		}
		n = n*10 + int64(s[i]-'0')
	}
	return n
}

// staleBackups: the apps whose daily backup is older than backup_hours (tando-watch's backup
// check's rule).
func (h *Host) staleBackups() []string {
	hours := watchSetting(readFile(filepath.Join(h.Env.Root, "alerts.conf"), 1<<20), "backup_hours", 50)
	var res []string
	for _, b := range h.backups() {
		if h.now()-b.Since > hours*3600 {
			res = append(res, b.App)
		}
	}
	return res
}

// rebootInput gathers the decision's inputs from the host.
func (h *Host) rebootInput(s Settings, st *State, manual, nowFlag bool) (RebootInput, error) {
	loc, err := s.Location(h.Loc)
	if err != nil {
		return RebootInput{}, err
	}
	ws, we, ok := ParseWindow(s["window"])
	if !ok {
		ws, we, _ = ParseWindow(careDefaults["window"])
	}
	var up int64
	if u := strings.Fields(string(readFile(filepath.Join(h.Env.Proc, "uptime"), 256))); len(u) > 0 {
		x, _, _ := strings.Cut(u[0], ".")
		up = num(x)
	}
	return RebootInput{
		Now: h.Env.Now(), Loc: loc, WindowStart: ws, WindowEnd: we, Manual: manual, NowFlag: nowFlag,
		Enabled: s["care_reboot"] == "on", Required: mtime(h.p("/run/reboot-required")) > 0,
		Skip: h.skipped(), Uptime: time.Duration(up) * time.Second, Busy: h.busy(),
		StaleBackups: h.staleBackups(), Proven: st.num("reboot.ok") > 0 || num(s["reboot_ok"]) > 0,
		CaddyOurs: h.caddyOurs(), OtherSitesOK: s["other_sites"] == "yes",
	}, nil
}

// bootID names this boot: the kernel's boot id and when PID 1 started (field 22 of
// /proc/1/stat). In a container the kernel is the host's: only PID 1's start changes there.
func bootID(proc string) string {
	id := clean(strings.TrimSpace(string(readFile(filepath.Join(proc, "sys/kernel/random/boot_id"), 64))), 40)
	st := string(readFile(filepath.Join(proc, "1", "stat"), 1024))
	if i := strings.LastIndexByte(st, ')'); i >= 0 {
		if f := strings.Fields(st[i+1:]); len(f) > 19 && num(f[19]) > 0 {
			id += "-" + f[19]
		}
	}
	return id
}

// writeMarker records a reboot about to happen, for after-boot (root 600).
func (h *Host) writeMarker(m map[string]string) error {
	if err := h.mkdir(); err != nil {
		return err
	}
	return saveMap(h.rebootPath(), m)
}
