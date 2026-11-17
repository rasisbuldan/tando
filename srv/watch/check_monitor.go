package watch

import (
	"path/filepath"

	"tando/srv/internal/decimal"
	"tando/srv/internal/fsinfo"
)

// checkMonitor: tandod, the daemon that runs these checks, is not doing so. Whoever runs this
// tick (the daemon when it is well, else the timer's one-shot) reads two things:
//
//   - tandod's health (DaemonStateFile): degraded since when and why (a panic, failed runs, runs
//     it did not survive). It fires once and resolves once, when tandod takes the checks back; the
//     daemon writes the state once per change, so a daemon that dies every hour is one alert, not
//     a message an hour.
//   - tandod's unit: failed (systemd gave up), restarting (auto-restart), or restarted twice or
//     more since the last run: a daemon that dies before it can write anything (at its start)
//     shows here.
//
// tandod stopped on purpose (inactive) is not a fault: the timer runs the checks then.
func checkMonitor(t *tick) {
	if !t.cfg.on("monitor", "") || !fsinfo.ExistsFollow(filepath.Join(t.w.Units, "tandod.service")) {
		return
	}
	u := t.units["_tandod"]
	nr, nr0 := u["NRestarts"], t.st.get("_host.monitor.nr")
	if decimal.IsDigits(nr) && nr != nr0 {
		t.st.set("_host.monitor.nr", nr)
	}
	var det string
	h := loadQuiet(t.w.daemonStateFile())
	switch {
	case h["degraded"] != "":
		since, _ := decimal.Parse(h["degraded"], 18)
		det = "tandod handed the checks to the timer " + dur(max(t.now-since, 0)) + " ago (" + or(h["reason"], "?") +
			"); the timer runs them meanwhile: journalctl -u tandod"
	case u["ActiveState"] == "failed":
		det = "tandod is not running (failed: " + or(u["Result"], "?") + "); the timer runs the checks: journalctl -u tandod"
	case u["ActiveState"] == "activating" && u["SubState"] == "auto-restart":
		det = "tandod keeps restarting (" + or(nr, "?") + " restarts; " + or(u["Result"], "?") + "); the timer runs the checks: journalctl -u tandod"
	case decimal.IsDigits(nr) && decimal.IsDigits(nr0) && num(nr, 0)-num(nr0, 0) >= 2:
		det = "tandod restarted " + decimal.Itoa(num(nr, 0)-num(nr0, 0)) + " times since the last run: journalctl -u tandod"
	}
	if det == "" {
		t.sample("_host.monitor", "_host", "monitor", ok, "", 1)
		return
	}
	t.sample("_host.monitor", "_host", "monitor", bad, det, 1)
}

// daemonStateFile is DaemonStateFile, in RunDir (tests).
func (w Watch) daemonStateFile() string {
	return filepath.Join(w.RunDir, filepath.Base(DaemonStateFile))
}
