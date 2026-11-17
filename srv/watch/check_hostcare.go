package watch

import (
	"os"
	"path/filepath"

	"tando/srv/internal/bashread"
)

// hostcareChecks are the alert checks of tando-host (docs/HOSTCARE.md). Their thresholds and
// their on/off live in /opt/tando/hostcare.conf, so the summary already says ok, bad or off.
var hostcareChecks = map[string]bool{
	"updates": true, "reboot": true, "exposed": true, "ssh": true, "units": true,
	"readonly": true, "ioerr": true, "clock": true, "eol": true, "boot": true,
}

// hostcareMaxAge: a summary older than this is not judged (tando-host writes it hourly).
const hostcareMaxAge = 3 * 3600

// checkHostcare reads /var/lib/tando/hostcare/summary (root 600, rewritten whole by tando-host)
// and samples one host check per "alert" row. Rows and trailing fields this reader does not know
// are ignored. An "off" row resolves a check that was firing.
//
// The summary's own age is the check "care": a summary older than 3 hours (or dated in the
// future, or of another format) fires it and holds the others, since stale facts neither fire nor
// resolve. No summary at all means host care is not installed: everything it had fired resolves.
func checkHostcare(t *tick) {
	p := filepath.Join(t.w.Env.Lib, "hostcare", "summary")
	fi, err := os.Lstat(p)
	if os.IsNotExist(err) {
		for c := range hostcareChecks {
			hostcareResolve(t, c)
		}
		hostcareResolve(t, "care")
		return
	}
	if err != nil || !fi.Mode().IsRegular() || fi.Size() > 1<<20 {
		return
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return
	}
	fresh, seen := false, false
	for _, l := range bashread.Lines(b) {
		f := bashread.Fields(l, 7)
		switch f[0] {
		case "summary":
			at := num(f[2], 0)
			seen = true
			fresh = f[1] == "1" && at > 0 && t.now-at <= hostcareMaxAge && at-t.now <= 300
			if !t.cfg.on("care", "") {
				continue
			}
			switch {
			case fresh:
				t.sample("_host.care", "_host", "care", ok, "", 1)
			case f[1] == "1" && at > 0 && at <= t.now:
				t.sample("_host.care", "_host", "care", bad, "the host checks last ran "+dur(t.now-at)+" ago: sudo systemctl status tando-host.timer", 1)
			default:
				t.sample("_host.care", "_host", "care", bad, "the host checks' summary is not readable: sudo tando-host check", 1)
			}
		case "alert":
			c := f[1]
			if !fresh || !hostcareChecks[c] || !t.cfg.on(c, "") {
				continue
			}
			switch f[2] {
			case "bad": // need 1: tando-host already applied its own time thresholds
				t.sample("_host."+c, "_host", c, bad, f[6], 1)
			case "ok", "off":
				t.sample("_host."+c, "_host", c, ok, "", 1)
			}
		}
	}
	if !seen && t.cfg.on("care", "") {
		t.sample("_host.care", "_host", "care", bad, "the host checks' summary is not readable: sudo tando-host check", 1)
	}
}

func hostcareResolve(t *tick, c string) {
	if k := "_host." + c; t.st.or(k+".st", "ok") != "ok" {
		t.sample(k, "_host", c, ok, "", 1)
	}
}
