package hostcare

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"tando/srv/internal/atomicfile"
	"tando/srv/internal/out"
	"tando/srv/internal/run"
)

// The units of host care (real unit files, written whole; no transient properties):
//
//	tando-host.timer / .service         `tando-host check` hourly (apt's facts every apt_hours)
//	tando-host-boot.service             `tando-host after-boot` once per boot: the check after a reboot
//	tando-host-window.timer / .service  `tando-host maintain` at the start of the maintenance
//	                                    window; only while care reboots or a reboot is planned
const unitCheck = `[Unit]
Description=tando host care: check the server (updates, security, health)
After=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/tando/bin/tando-host check
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=20min
`

const unitTimer = `[Unit]
Description=tando host care: hourly check

[Timer]
OnBootSec=5min
OnCalendar=hourly
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
`

const unitBoot = `[Unit]
Description=tando host care: after a reboot by tando, check that every app answers
After=network-online.target tando-recover.service caddy.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/tando/bin/tando-host after-boot
TimeoutStartSec=15min

[Install]
WantedBy=multi-user.target
`

const unitWindow = `[Unit]
Description=tando host care: the maintenance window (a reboot when one is needed and allowed)

[Service]
Type=oneshot
ExecStart=/opt/tando/bin/tando-host maintain
TimeoutStartSec=%dmin
`

const unitWindowTimer = `[Unit]
Description=tando host care: the maintenance window %s

[Timer]
OnCalendar=*-*-* %02d:%02d:00%s
Persistent=false

[Install]
WantedBy=timers.target
`

func (h *Host) unitPath(n string) string { return h.p(filepath.Join("/etc/systemd/system", n)) }

// installUnits writes the units that differ and starts what is new. The window's units exist
// only while care reboots or a reboot is planned. It says what changed.
func (h *Host) installUnits(ctx context.Context, s Settings, st *State) (string, error) {
	write := func(n, text string) (bool, error) {
		return atomicfile.WriteIfChanged(h.unitPath(n), []byte(text), atomicfile.Mode(0o644))
	}
	var changed []string
	for _, u := range []struct{ n, t string }{{"tando-host.service", unitCheck}, {"tando-host.timer", unitTimer}, {"tando-host-boot.service", unitBoot}} {
		ch, err := write(u.n, u.t)
		if err != nil {
			return "", err
		}
		if ch {
			changed = append(changed, u.n)
		}
	}
	windowOn := s["care_reboot"] == "on" || st.num("planned") > 0
	winChanged := false
	if windowOn {
		ws, we, ok := ParseWindow(s["window"])
		if !ok {
			ws, we, _ = ParseWindow(careDefaults["window"])
		}
		length := (we - ws + 24*60) % (24 * 60)
		tz := ""
		if s["tz"] != "" && tzRe.MatchString(s["tz"]) {
			tz = " " + s["tz"]
		}
		a, err := write("tando-host-window.service", fmt.Sprintf(unitWindow, length+30))
		if err != nil {
			return "", err
		}
		b, err := write("tando-host-window.timer", fmt.Sprintf(unitWindowTimer, s["window"], ws/60, ws%60, tz))
		if err != nil {
			return "", err
		}
		winChanged = a || b
	} else {
		for _, n := range []string{"tando-host-window.timer", "tando-host-window.service"} {
			if _, err := os.Stat(h.unitPath(n)); err == nil {
				if n == "tando-host-window.timer" {
					h.Env.Run.Output(ctx, run.Cmd{Argv: []string{"systemctl", "disable", "-q", "--now", "tando-host-window.timer"}, Timeout: time.Minute})
				}
				os.Remove(h.unitPath(n))
				winChanged = true
			}
		}
	}
	if winChanged {
		changed = append(changed, "maintenance window")
	}
	if len(changed) > 0 {
		h.Env.Run.Output(ctx, run.Cmd{Argv: []string{"systemctl", "daemon-reload"}, Timeout: time.Minute})
	}
	h.Env.Run.Output(ctx, run.Cmd{Argv: []string{"systemctl", "enable", "-q", "--now", "tando-host.timer"}, Timeout: time.Minute})
	h.Env.Run.Output(ctx, run.Cmd{Argv: []string{"systemctl", "enable", "-q", "tando-host-boot.service"}, Timeout: time.Minute})
	if windowOn {
		if winChanged {
			h.Env.Run.Output(ctx, run.Cmd{Argv: []string{"systemctl", "restart", "tando-host-window.timer"}, Timeout: time.Minute})
		}
		h.Env.Run.Output(ctx, run.Cmd{Argv: []string{"systemctl", "enable", "-q", "--now", "tando-host-window.timer"}, Timeout: time.Minute})
	}
	if len(changed) == 0 {
		return "", nil
	}
	return "units: " + strings.Join(changed, ", "), nil
}

// Install is the verb `install [care=on|off]` (tando host setup): the units, a first check, and
// on a server whose Caddy tando installed itself, care's security updates unless the owner
// said care=off or decided before (then nothing changes).
func (h *Host) Install(ctx context.Context, o *out.Writer, args []string) error {
	if err := h.needRoot(); err != nil {
		return err
	}
	want := ""
	for _, a := range args {
		switch a {
		case "care=on", "care=off", "care=auto":
			want = strings.TrimPrefix(a, "care=")
		default:
			return fmt.Errorf("install: unknown word %s", clean(a, 40))
		}
	}
	l, err := h.lock()
	if err != nil {
		return err
	}
	m := loadOwn(h.confPath())
	_, decided := m["care_updates"]
	ours := h.caddyOurs()
	turnOn := want == "on" || (want != "off" && !decided && ours && h.caddyInstalledByTando())
	note := ""
	switch {
	case want == "off" && m["care_updates"] == "on":
		note = h.removeCareUpdates(ctx)
		m["care_updates"] = "off"
	case want == "off":
		m["care_updates"] = "off"
	case turnOn && m["care_updates"] != "on":
		d, err := h.applyCareUpdates(ctx)
		if err != nil {
			l.Release()
			return err
		}
		note, m["care_updates"] = d, "on"
		h.audit(ctx, "host-care", true, "on (host setup): "+d)
	case turnOn:
		if d, err := h.applyCareUpdates(ctx); err == nil {
			note = d
		}
	}
	if err := saveSettings(h.confPath(), m); err != nil {
		l.Release()
		return err
	}
	st := loadState(h.statePath())
	if _, err := h.installUnits(ctx, LoadSettings(h.confPath()), st); err != nil {
		l.Release()
		return err
	}
	l.Release()
	o.KV("care_updates", LoadSettings(h.confPath())["care_updates"])
	o.KV("care_reboot", LoadSettings(h.confPath())["care_reboot"])
	o.KV("caddy_ours", b01(ours))
	o.KV("changed", note)
	return nil
}

// caddyInstalledByTando: host setup installed Caddy (host.conf caddy_installed=yes): a server
// tando set up from empty, where care's updates are on unless the owner says otherwise.
func (h *Host) caddyInstalledByTando() bool {
	return strings.Contains(string(readFile(filepath.Join(h.Env.Root, "host.conf"), 1<<20)), "\ncaddy_installed=yes") ||
		strings.HasPrefix(string(readFile(filepath.Join(h.Env.Root, "host.conf"), 1<<20)), "caddy_installed=yes")
}
