package watch

import (
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"tando/srv/internal/bashread"
	"tando/srv/internal/decimal"
	"tando/srv/internal/run"
)

var exitRe = regexp.MustCompile(`code=(exited|killed|dumped), status=([0-9]+)`)

// countRestarts: restarts since the last run (NRestarts drops to 0 on a manual restart or a
// reboot), and how the app's main process last ended (a crash: exit status or signal, and
// whether the kernel's OOM killer did it), for the details of down and restarts.
// NRestarts also begins again when tando's recover starts an app systemd gave up on (start
// limit); the agent keeps the count it had then (plus that start) in the state's restarts_lost,
// added here, so a crash loop that ended and was restarted between two runs is still counted.
func countRestarts(t *tick, a *appTick) {
	k := a.name
	nr0, had := t.st.lookup(k + ".nr")
	nr := a.unit["NRestarts"]
	if nr == "" { // unknown this run: keep the baseline
		nr = or(nr0, "0")
	} else {
		nr = RestartsWithLost(nr, a.state["restarts_lost"])
	}
	if had && nr0 != "" && num(nr, 0) > num(nr0, 0) {
		a.newRestarts = num(nr, 0) - num(nr0, 0)
	}
	if nr0 != nr {
		t.st.set(k+".nr", nr)
	}
	if !a.hasUnit {
		return // a static app has no process: nothing ended (the shell asked the journal anyway,
		// once a minute for every static app)
	}
	xc, xs := a.unit["ExecMainCode"], a.unit["ExecMainStatus"]
	// systemd's own line about the last exit (the unit's ExecMain* already describe the new
	// process after an automatic restart): read when the app restarted or is not running, but
	// once per change of the unit's state and restart count, never for a stopped app. Each
	// journalctl opens every file of the system journal; a failed app asked it every minute and
	// re-read the journal inside tandod's memory cap. vs xi.<app>: "<state>/<NRestarts> <code>
	// <status>", what that read found (volatile: after a reboot it is read once more).
	ck, sig := "xi."+a.name, a.unit["ActiveState"]+"/"+nr
	switch {
	case a.stopped:
	case a.newRestarts == 0 && a.unit["ActiveState"] == "active":
		t.vs.del(ck) // running: the next stop or crash reads afresh
	default:
		if c := strings.Fields(t.vs.get(ck)); len(c) == 3 && c[0] == sig {
			xc, xs = c[1], c[2]
			break
		}
		out, _ := t.w.Env.Run.Output(t.ctx, run.Cmd{
			Argv: []string{"journalctl", "-q", "--no-pager", "-o", "cat", "-u", "tando-" + a.name + ".service",
				"--since=@" + decimal.Itoa(t.now-900), "-g", "process exited, code="},
			Env: cmdEnv, Timeout: 10 * time.Second,
		})
		ls := bashread.Lines(out)
		if len(ls) > 0 {
			if m := exitRe.FindStringSubmatch(ls[len(ls)-1]); m != nil {
				xc, xs = map[string]string{"exited": "1", "killed": "2", "dumped": "3"}[m[1]], m[2]
			}
		}
		if decimal.IsDigits(xc) && decimal.IsDigits(xs) {
			t.vs.set(ck, sig+" "+xc+" "+xs)
		}
	}
	var xi string
	switch xc {
	case "1":
		if xs != "0" {
			xi = "exit status " + xs
		}
	case "2":
		xi = "killed by " + signame(xs)
	case "3":
		xi = "core dumped (" + signame(xs) + ")"
	}
	xo := evcount(filepath.Join(t.w.appCgroup(a.name), "memory.events"), "oom_kill")
	if xo > t.vs.n("oomk."+a.name, xo) || (t.st.get(k+".oom_t") != "" && t.now-t.st.n(k+".oom_t", 0) < 600) {
		xi = join(xi, ", ", "OOM-killed at its memory cap "+or(a.conf["memory"], "?"))
	}
	a.exitInfo = xi
}

// join is a+sep+b, or b when a is empty (bash ${a:+$a$sep}$b).
func join(a, sep, b string) string {
	if a == "" {
		return b
	}
	return a + sep + b
}

// suffix is pre+s, or nothing when s is empty (bash ${s:+$pre$s}).
func suffix(pre, s string) string {
	if s == "" {
		return ""
	}
	return pre + s
}

// checkDown: the unit is not running, failed, or restarting again and again. A stopped app
// (tando stop) is not an outage; a static app has no unit. While down is not ok, the checks
// after it are held: a dead app gives one alert, not four.
func checkDown(t *tick, a *appTick) {
	u := a.unit
	st, sub, res := u["ActiveState"], u["SubState"], u["Result"]
	xi := a.exitInfo
	det := ""
	switch {
	case a.stopped:
		a.down = "stopped"
	case !a.hasUnit:
		a.down = "nounit"
	case a.hold:
		a.down = "hold"
	case a.idle && st == "inactive":
		a.down = "idle" // (idle_stop) stopped for want of requests: started by the next one
	case st == "active":
		a.down = "ok"
		if a.newRestarts >= 2 {
			a.down = "bad"
			det = "crash-looping: " + decimal.Itoa(a.newRestarts) + " restarts in the last minute" + suffix("; last: ", xi)
		}
	case st == "activating" && sub == "auto-restart":
		a.down, det = "bad", "crash-looping (restarting; last result: "+res+suffix(", ", xi)+")"
	case st == "failed":
		a.down, det = "bad", "failed ("+or(res, "unknown")+suffix(", ", xi)+"); systemd gave up restarting it"
	case st == "inactive":
		a.down, det = "bad", "not running (inactive"+suffix(", ", xi)+"; not stopped with tando stop)"
	default:
		a.down = "hold" // activating, deactivating, reloading
	}
	k := a.key("down")
	switch {
	case a.down == "stopped" || a.down == "idle":
		if t.st.get(k+".st") != "" {
			t.sample(k, a.name, "down", ok, "", 1)
		}
		a.hold = true
	case a.down == "nounit":
		a.down = "ok"
	case t.cfg.on("down", a.name):
		t.sample(k, a.name, "down", resultOf(a.down), det, t.cfg.num("down_after", a.name))
	}
	if a.down != "ok" {
		a.hold = true // the checks below need a running app
	}
}

func resultOf(s string) result {
	switch s {
	case "ok":
		return ok
	case "bad":
		return bad
	}
	return hold
}

// checkRestarts: automatic restarts within restarts_window (a crash loop is "down" instead).
func checkRestarts(t *tick, a *appTick) {
	if !a.hasUnit || !t.cfg.on("restarts", a.name) {
		return
	}
	k := a.key("restarts")
	rt := t.st.get(a.name + ".rt")
	win, rmax := t.cfg.num("restarts_window", a.name), t.cfg.num("restarts_max", a.name)
	var keep []string
	for _, x := range splitList(rt) {
		if t.now-num(x, 0) < win*60 {
			keep = append(keep, x)
		}
	}
	if !a.hold && a.newRestarts > 0 {
		for x := int64(0); x < a.newRestarts && x < 10; x++ {
			keep = append(keep, decimal.Itoa(t.now))
		}
	}
	if out := strings.Join(keep, ","); out != rt {
		if out != "" {
			t.st.set(a.name+".rt", out)
		} else {
			t.st.del(a.name + ".rt")
		}
	}
	n := int64(len(keep))
	switch {
	case n >= rmax:
		t.sample(k, a.name, "restarts", bad, decimal.Itoa(n)+" automatic restarts within "+decimal.Itoa(win)+" min"+suffix("; last: ", a.exitInfo), 1)
	case !a.hold || n == 0:
		t.sample(k, a.name, "restarts", ok, "", 1)
	}
}

// RestartsWithLost is systemd's NRestarts plus the restarts tando's recover took from it (the
// state's restarts_lost); nr unchanged when either is not a number.
func RestartsWithLost(nr, lost string) string {
	if !decimal.IsDigits(nr) || !decimal.IsDigits(lost) || len(nr) > 9 || len(lost) > 9 {
		return nr
	}
	return decimal.Itoa(num(nr, 0) + num(lost, 0))
}
