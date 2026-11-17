package hostcare

import (
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
	"time"

	"tando/srv/internal/atomicfile"
	"tando/srv/internal/bashread"
	"tando/srv/internal/decimal"
	"tando/srv/internal/kvfile"
	"tando/srv/internal/out"
)

// Settings are /opt/tando/hostcare.conf (root 644, key=value) over the defaults. The alert
// thresholds are changed with `tando alerts set` (the client sends these keys to tando-host
// set), the care keys only by `tando host care` (root, from the owner's laptop).
type Settings map[string]string

// alertDefaults are the alert checks of host care and their thresholds, in the order `settings`
// lists them. "<check>=off" turns a check off.
var alertDefaults = []struct{ key, def, desc string }{
	{"updates", "on", "security updates pending too long, or unattended-upgrades failing"},
	{"updates_days", "3", "days a security update may wait before updates fires"},
	{"reboot", "on", "the server needs a reboot (a new kernel or library) for too long"},
	{"reboot_days", "7", "days a needed reboot may wait before reboot fires"},
	{"exposed", "on", "a port open to the world that is not ssh or Caddy (high priority)"},
	{"allow_ports", "-", "ports you mean to be open, e.g. tcp/5432,udp/51820 (not reported as exposed)"},
	{"ssh", "on", "ssh allows password or root login (low priority, a reminder a day)"},
	{"units", "on", "systemd units that failed (tando apps are the down check's)"},
	{"readonly", "on", "a file system that should be writable is mounted read-only (high)"},
	{"ioerr", "on", "disk I/O errors in the kernel log in the last 24 h (high)"},
	{"clock", "on", "the clock is not synchronised (NTP) for too long"},
	{"clock_min", "60", "minutes without time synchronisation before clock fires"},
	{"eol", "on", "the Ubuntu release is past, or near, the end of its standard support"},
	{"eol_days", "60", "days before the end of support at which eol fires"},
	{"boot", "on", "/boot nearly full (kernel updates fail)"},
	{"boot_pct", "90", "% of /boot used at which boot fires"},
	{"apt_hours", "6", "hours between the checks of apt (package lists, pending updates)"},
}

// careDefaults: what `tando host care` sets (not `tando alerts set`).
var careDefaults = map[string]string{
	"care_updates": "off",         // install security updates automatically (unattended-upgrades)
	"care_reboot":  "off",         // reboot automatically in the window when one is needed
	"window":       "02:00-04:00", // the maintenance window (care_reboot, tando host reboot)
	"tz":           "",            // its time zone (IANA name); empty: the server's
	"lead_min":     "10",          // minutes between the notice and the reboot
	"other_sites":  "no",          // yes: reboot although Caddy serves sites tando does not own
	"reboot_ok":    "",            // epoch the owner confirmed automatic reboots
}

// AlertChecks are the alert checks of the summary file, in this order.
var AlertChecks = []string{"updates", "reboot", "exposed", "ssh", "units", "readonly", "ioerr", "clock", "eol", "boot"}

func alertDefault(k string) (string, bool) {
	for _, d := range alertDefaults {
		if d.key == k {
			return d.def, true
		}
	}
	return "", false
}

// LoadSettings reads the file over the defaults; a missing or unreadable file is the defaults.
func LoadSettings(path string) Settings {
	s := Settings{}
	for _, d := range alertDefaults {
		s[d.key] = d.def
	}
	for k, v := range careDefaults {
		s[k] = v
	}
	if m, err := kvfile.Load(path); err == nil {
		for k, v := range m {
			s[k] = v
		}
	}
	return s
}

// On: the check is not "off".
func (s Settings) On(check string) bool { return s[check] != "off" }

// Num is a numeric setting; a malformed value is its default.
func (s Settings) Num(k string) int64 {
	if n, ok := decimal.Parse(s[k], 9); ok {
		return n
	}
	d, _ := alertDefault(k)
	if n, ok := decimal.Parse(d, 9); ok {
		return n
	}
	n, _ := decimal.Parse(careDefaults[k], 9)
	return n
}

var (
	portSpecRe = regexp.MustCompile(`^(tcp|udp)/[0-9]{1,5}$`)
	windowRe   = regexp.MustCompile(`^([01][0-9]|2[0-3]):([0-5][0-9])-([01][0-9]|2[0-3]):([0-5][0-9])$`)
	tzRe       = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_+-]{0,30}(/[A-Za-z0-9_+-]{1,30}){0,2}$`)
)

// AllowedPorts are the ports of allow_ports ("tcp/5432,udp/51820").
func (s Settings) AllowedPorts() map[string]bool {
	m := map[string]bool{}
	for _, p := range strings.Split(s["allow_ports"], ",") {
		if p = strings.TrimSpace(p); portSpecRe.MatchString(p) {
			m[p] = true
		}
	}
	return m
}

// checkSetting validates one key=value of `set` (alert keys only); "" goes back to the default.
func checkSetting(k, v string) error {
	def, ok := alertDefault(k)
	if !ok {
		if _, care := careDefaults[k]; care {
			return fmt.Errorf("%s is a care setting: tando host care", k)
		}
		return fmt.Errorf("unknown setting: %s", k)
	}
	switch {
	case v == "":
		return nil
	case def == "on":
		if v != "on" && v != "off" {
			return fmt.Errorf("%s is on or off", k)
		}
	case k == "allow_ports":
		if v == "-" {
			return nil
		}
		for _, p := range strings.Split(v, ",") {
			if !portSpecRe.MatchString(p) {
				return fmt.Errorf("allow_ports: %q is not like tcp/5432 or udp/51820", p)
			}
			if n, _ := decimal.Parse(p[4:], 5); n < 1 || n > 65535 {
				return fmt.Errorf("allow_ports: port %s out of range", p[4:])
			}
		}
	default:
		n, ok := decimal.Parse(v, 6)
		if !ok {
			return fmt.Errorf("%s needs a number", k)
		}
		if k == "boot_pct" && (n < 50 || n > 100) {
			return fmt.Errorf("boot_pct is 50 to 100")
		}
		if k == "apt_hours" && (n < 1 || n > 168) {
			return fmt.Errorf("apt_hours is 1 to 168")
		}
	}
	return nil
}

// ParseWindow reads "02:00-04:00" as minutes after midnight (the end may be before the start:
// a window across midnight).
func ParseWindow(w string) (start, end int, ok bool) {
	m := windowRe.FindStringSubmatch(w)
	if m == nil {
		return 0, 0, false
	}
	n := func(s string) int { x, _ := decimal.Parse(s, 2); return int(x) }
	start, end = n(m[1])*60+n(m[2]), n(m[3])*60+n(m[4])
	return start, end, start != end
}

// Location is the window's time zone: tz, else the server's (/etc/localtime, read by Go).
func (s Settings) Location(fallback *time.Location) (*time.Location, error) {
	if s["tz"] == "" {
		return fallback, nil
	}
	if !tzRe.MatchString(s["tz"]) {
		return nil, fmt.Errorf("bad time zone %q", s["tz"])
	}
	return time.LoadLocation(s["tz"])
}

// saveSettings writes the file (root 644: the settings are not secrets; only root writes them).
func saveSettings(path string, m map[string]string) error {
	_, err := kvfile.Save(path, m, atomicfile.Mode(0o644))
	return err
}

// loadOwn reads only what is in the file (no defaults), for changing it.
func loadOwn(path string) map[string]string {
	m, err := kvfile.Load(path)
	if err != nil || m == nil {
		return map[string]string{}
	}
	return m
}

// Set is the verb `set`: key=value lines on stdin (the alert keys of host care; `key=` goes
// back to the default). Everything is checked before anything is written.
func (h *Host) Set(o *out.Writer, stdin io.Reader) error {
	if err := h.needRoot(); err != nil {
		return err
	}
	b, err := io.ReadAll(io.LimitReader(stdin, 64<<10))
	if err != nil {
		return err
	}
	l, err := h.lock()
	if err != nil {
		return err
	}
	defer l.Release()
	m := loadOwn(h.confPath())
	var changed []string
	for _, kv := range bashread.Lines(b) {
		if kv == "" {
			continue
		}
		k, v, ok := strings.Cut(kv, "=")
		if !ok {
			return fmt.Errorf("expected key=value: %s", clean(kv, 60))
		}
		if hasCtl(v) || hasCtl(k) {
			return fmt.Errorf("control characters in %s", clean(k, 40))
		}
		if err := checkSetting(k, v); err != nil {
			return err
		}
		if v == "" {
			delete(m, k)
		} else {
			m[k] = v
		}
		changed = append(changed, k)
	}
	if err := saveSettings(h.confPath(), m); err != nil {
		return err
	}
	o.KV("ok", "1")
	o.KV("changed", strings.Join(changed, ","))
	return nil
}

// ShowSettings is the verb `settings`: "conf key value description" rows (tando alerts set).
func (h *Host) ShowSettings(o *out.Writer) error {
	s := LoadSettings(h.confPath())
	for _, d := range alertDefaults {
		o.Row("conf", d.key, s[d.key], d.desc)
	}
	return nil
}

func hasCtl(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < 0x20 || s[i] == 0x7f {
			return true
		}
	}
	return false
}

func readSmall(p string, max int64) []byte {
	f, err := os.Open(p)
	if err != nil {
		return nil
	}
	defer f.Close()
	b, _ := io.ReadAll(io.LimitReader(f, max))
	return b
}
