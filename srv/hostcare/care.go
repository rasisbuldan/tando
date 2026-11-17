package hostcare

import (
	"context"
	"errors"
	"os"
	"strconv"
	"strings"
	"time"

	"tando/srv/internal/atomicfile"
	"tando/srv/internal/kvfile"
	"tando/srv/internal/out"
	"tando/srv/internal/run"
)

// What care mode changes on the server, all in files of its own (care off removes them; the
// files of Ubuntu's packages are never edited):
//
//	/etc/apt/apt.conf.d/52tando-care     unattended-upgrades on, every day, security origins only,
//	                                     no automatic reboot of its own
//	/etc/systemd/system/apt-daily-upgrade.service.d/tando-care.conf
//	                                     NEEDRESTART_SUSPEND=1: the upgrades restart no service
//	                                     tando does not manage (needrestart's automatic restarts);
//	                                     what still runs old code is listed by tando host status
//	the unattended-upgrades package      installed when missing (it is part of Ubuntu server)
//	/etc/systemd/system/tando-host-window.{service,timer}   care reboot: the maintenance window

const (
	aptCareFile   = "/etc/apt/apt.conf.d/52tando-care"
	uuDropinDir   = "/etc/systemd/system/apt-daily-upgrade.service.d"
	uuDropinFile  = uuDropinDir + "/tando-care.conf"
	aptLog        = "/var/log/tando-apt.log"
	aptCareConfig = `// tando host care (docs/HOSTCARE.md): written by tando, removed by tando host care off.
// Security updates only, every day; no reboot by unattended-upgrades (tando reboots in its
// maintenance window when you allow it: tando host care on --reboot).
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Allowed-Origins {
	"${distro_id}:${distro_codename}-security";
	"${distro_id}ESMApps:${distro_codename}-apps-security";
	"${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
`
	uuDropin = `# tando host care: package upgrades must not restart services tando does not manage
# (needrestart restarts them on its own otherwise); tando host status lists what runs old code.
[Service]
Environment=NEEDRESTART_SUSPEND=1
`
)

// aptEnv is the environment of apt and dpkg runs: no questions, and needrestart's automatic
// restarts suspended (the agent's apt_install does the same).
var aptEnv = []string{"PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL=C", "DEBIAN_FRONTEND=noninteractive", "NEEDRESTART_SUSPEND=1"}

// logFile opens tando's apt log for appending (root 640).
func (h *Host) logFile() *os.File {
	f, err := os.OpenFile(h.p(aptLog), os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o640)
	if err != nil {
		return nil
	}
	return f
}

// applyCareUpdates installs unattended-upgrades when it is missing and writes care's files. It
// says what it changed ("" when nothing did).
func (h *Host) applyCareUpdates(ctx context.Context) (string, error) {
	var did []string
	d := ParseDpkgStatus(readFile(h.p("/var/lib/dpkg/status"), 32<<20), "unattended-upgrades")
	if _, ok := d.Installed["unattended-upgrades"]; !ok {
		lf := h.logFile()
		if lf != nil {
			defer lf.Close()
		}
		c := run.Cmd{Argv: []string{"apt-get", "update", "-q"}, Env: aptEnv, Timeout: 10 * time.Minute, Stdout: lf, Stderr: lf}
		h.Env.Run.Output(ctx, c)
		c.Argv = []string{"apt-get", "install", "-y", "-q", "-o", "Dpkg::Options::=--force-confdef", "-o", "Dpkg::Options::=--force-confold", "unattended-upgrades"}
		if _, err := h.Env.Run.Output(ctx, c); err != nil {
			return "", errors.New("could not install unattended-upgrades with apt: sudo tail -20 " + aptLog + " (on the server) says why")
		}
		did = append(did, "installed unattended-upgrades")
	}
	ch, err := atomicfile.WriteIfChanged(h.p(aptCareFile), []byte(aptCareConfig), atomicfile.Mode(0o644))
	if err != nil {
		return "", err
	}
	if ch {
		did = append(did, "security updates every day ("+aptCareFile+")")
	}
	if err := os.MkdirAll(h.p(uuDropinDir), 0o755); err != nil {
		return "", err
	}
	ch, err = atomicfile.WriteIfChanged(h.p(uuDropinFile), []byte(uuDropin), atomicfile.Mode(0o644))
	if err != nil {
		return "", err
	}
	if ch {
		did = append(did, "no service restarts by needrestart")
		h.Env.Run.Output(ctx, run.Cmd{Argv: []string{"systemctl", "daemon-reload"}, Timeout: time.Minute})
	}
	h.Env.Run.Output(ctx, run.Cmd{Argv: []string{"systemctl", "enable", "-q", "--now", "apt-daily.timer", "apt-daily-upgrade.timer"}, Timeout: time.Minute})
	return strings.Join(did, "; "), nil
}

// removeCareUpdates removes care's files (unattended-upgrades stays as Ubuntu set it up).
func (h *Host) removeCareUpdates(ctx context.Context) string {
	var did []string
	if os.Remove(h.p(aptCareFile)) == nil {
		did = append(did, "removed "+aptCareFile)
	}
	if os.Remove(h.p(uuDropinFile)) == nil {
		os.Remove(h.p(uuDropinDir)) // (only when empty)
		h.Env.Run.Output(ctx, run.Cmd{Argv: []string{"systemctl", "daemon-reload"}, Timeout: time.Minute})
		did = append(did, "removed the needrestart guard")
	}
	return strings.Join(did, "; ")
}

// Care is the verb `care`: what care mode does here, as key=value lines.
func (h *Host) Care(o *out.Writer) error {
	s := LoadSettings(h.confPath())
	st := loadState(h.statePath())
	for _, k := range []string{"care_updates", "care_reboot", "window", "tz", "lead_min", "other_sites"} {
		o.KV(k, s[k])
	}
	o.KV("proven", b01(st.num("reboot.ok") > 0 || num(s["reboot_ok"]) > 0))
	o.KV("caddy_ours", b01(h.caddyOurs()))
	o.KV("skip", b01(h.skipped()))
	o.KV("planned", st.get("planned"))
	_, err := os.Stat(h.p(aptCareFile))
	o.KV("care_file", b01(err == nil))
	if loc, err := s.Location(h.Loc); err == nil {
		if ws, _, ok := ParseWindow(s["window"]); ok {
			o.KV("next_window", i64(NextWindow(h.Env.Now(), loc, ws).Unix()))
		}
		o.KV("zone", loc.String())
	}
	o.KV("last_reboot_ok", st.get("reboot.ok"))
	return nil
}

// CareOn is the verb `care-on [updates] [reboot] [window=HH:MM-HH:MM] [tz=Zone] [lead=N]
// [other-sites] [confirmed]`. reboot needs confirmed (the owner typed the host name) unless a
// reboot by tando came back healthy before; with sites tando does not manage it needs
// other-sites too. A second run with the same words changes nothing.
func (h *Host) CareOn(ctx context.Context, o *out.Writer, args []string) error {
	if err := h.needRoot(); err != nil {
		return err
	}
	var upd, reb, other, confirmed bool
	set := map[string]string{}
	for _, a := range args {
		switch k, v, _ := strings.Cut(a, "="); {
		case a == "updates":
			upd = true
		case a == "reboot":
			reb = true
		case a == "other-sites":
			other = true
		case a == "confirmed":
			confirmed = true
		case k == "window":
			if _, _, ok := ParseWindow(v); !ok {
				return errors.New("the window is like 02:00-04:00 (24-hour clock, start and end differ)")
			}
			set["window"] = v
		case k == "tz":
			if !tzRe.MatchString(v) {
				return errors.New("bad time zone: " + clean(v, 40))
			}
			if _, err := time.LoadLocation(v); err != nil {
				return errors.New("unknown time zone on the server: " + clean(v, 40) + " (like Asia/Jakarta or UTC)")
			}
			set["tz"] = v
		case k == "lead":
			n, ok := strconv.Atoi(v)
			if ok != nil || n < 0 || n > 120 {
				return errors.New("lead is 0 to 120 minutes")
			}
			set["lead_min"] = strconv.Itoa(n)
		default:
			return errors.New("care-on: unknown word " + clean(a, 40))
		}
	}
	l, err := h.lock()
	if err != nil {
		return err
	}
	defer l.Release()
	m := loadOwn(h.confPath())
	st := loadState(h.statePath())
	for k, v := range set {
		m[k] = v
	}
	var did []string
	if upd {
		d, err := h.applyCareUpdates(ctx)
		if err != nil {
			return err
		}
		if d != "" {
			did = append(did, d)
		}
		m["care_updates"] = "on"
	}
	if reb {
		ours := h.caddyOurs()
		if !ours && !other {
			return errors.New("Caddy on this server also serves sites tando does not manage: an automatic reboot takes them down too. To allow it anyway: tando host care on --reboot --even-with-other-sites")
		}
		proven := st.num("reboot.ok") > 0 || num(m["reboot_ok"]) > 0
		if !proven && !confirmed {
			return errors.New("automatic reboots need your confirmation (or one tando host reboot that came back healthy)")
		}
		if confirmed && !proven {
			m["reboot_ok"] = i64(h.now())
		}
		if !ours {
			m["other_sites"] = "yes"
		}
		m["care_reboot"] = "on"
	}
	if err := saveSettings(h.confPath(), m); err != nil {
		return err
	}
	s := LoadSettings(h.confPath())
	if ch, err := h.installUnits(ctx, s, st); err != nil {
		return err
	} else if ch != "" {
		did = append(did, ch)
	}
	if len(did) > 0 {
		h.audit(ctx, "host-care", true, "on: "+strings.Join(did, "; "))
	}
	o.KV("changed", strings.Join(did, "; "))
	return h.Care(o)
}

// CareOff is the verb `care-off [updates] [reboot]` (no word: both).
func (h *Host) CareOff(ctx context.Context, o *out.Writer, args []string) error {
	if err := h.needRoot(); err != nil {
		return err
	}
	upd, reb := len(args) == 0, len(args) == 0
	for _, a := range args {
		switch a {
		case "updates":
			upd = true
		case "reboot":
			reb = true
		default:
			return errors.New("care-off: unknown word " + clean(a, 40))
		}
	}
	l, err := h.lock()
	if err != nil {
		return err
	}
	defer l.Release()
	m := loadOwn(h.confPath())
	st := loadState(h.statePath())
	var did []string
	if upd {
		if d := h.removeCareUpdates(ctx); d != "" {
			did = append(did, d)
		}
		if m["care_updates"] == "on" {
			did = append(did, "automatic security updates no longer managed by tando")
		}
		delete(m, "care_updates")
	}
	if reb {
		if m["care_reboot"] == "on" {
			did = append(did, "no automatic reboots")
		}
		delete(m, "care_reboot")
		delete(m, "other_sites")
	}
	if err := saveSettings(h.confPath(), m); err != nil {
		return err
	}
	if ch, err := h.installUnits(ctx, LoadSettings(h.confPath()), st); err != nil {
		return err
	} else if ch != "" {
		did = append(did, ch)
	}
	if len(did) > 0 {
		h.audit(ctx, "host-care", true, "off: "+strings.Join(did, "; "))
	}
	o.KV("changed", strings.Join(did, "; "))
	return h.Care(o)
}

// CareSkip is the verb `care-skip`: the next automatic reboot does not happen (also one that is
// counting down: it is cancelled within seconds). `care-skip off` takes it back. A file of its
// own (not the state): a reboot counting down holds the lock and rewrites the state.
func (h *Host) CareSkip(ctx context.Context, o *out.Writer, args []string) error {
	if err := h.needRoot(); err != nil {
		return err
	}
	if err := h.mkdir(); err != nil {
		return err
	}
	if len(args) > 0 && args[0] == "off" {
		os.Remove(h.skipPath())
	} else {
		if err := atomicfile.Write(h.skipPath(), []byte(i64(h.now())+"\n"), atomicfile.Mode(0o600)); err != nil {
			return err
		}
		h.audit(ctx, "host-reboot", true, "the next automatic reboot is skipped")
	}
	o.KV("skip", b01(h.skipped()))
	return nil
}

func (h *Host) skipPath() string { return h.dir() + "/skip" }
func (h *Host) skipped() bool    { return mtime(h.skipPath()) > 0 }

func saveMap(p string, m map[string]string) error {
	_, err := kvfile.Save(p, m, atomicfile.Mode(0o600))
	return err
}
