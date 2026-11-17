package watch

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"tando/srv/internal/decimal"
	"tando/srv/internal/run"
)

// checkCaddy: every app is reached through Caddy, so one bad sample fires; while it is down the
// apps' health probes are held (they would all fail with it). A restart in progress is held.
func checkCaddy(t *tick) {
	u := t.units["_caddy"]
	cs, csub := u["ActiveState"], u["SubState"]
	t.caddyUp = true
	switch {
	case cs == "hold":
		t.caddyUp = false
	case cs != "active" && cs != "reloading":
		t.caddyUp = false
		if t.cfg.on("caddy", "") && !(cs == "activating" && csub == "auto-restart") {
			s := cs
			if s == "" {
				s = "unknown"
			}
			if r := u["Result"]; r != "" {
				s += ", " + r
			}
			t.sample("_host.caddy", "_host", "caddy", bad, "Caddy is not running ("+s+"): every app is unreachable", 1)
		}
	case t.cfg.on("caddy", ""):
		t.sample("_host.caddy", "_host", "caddy", ok, "", 1)
	}
}

// checkCaddyConfig validates the Caddy config on disk, only when a file under /etc/caddy is
// newer than the last validation and at most every caddy_every minutes (caddy validate costs a
// few hundred ms). tando itself validates before every reload; this catches hand edits that
// would break the next reload or restart. The verdict is kept in /run, so a reboot validates
// once more.
func checkCaddyConfig(t *tick) {
	if !t.cfg.on("caddy_config", "") {
		return
	}
	ref := filepath.Join(t.w.RunDir, "caddy.checked")
	if t.caddyChanged(ref) {
		every := t.cfg.num("caddy_every", "")
		if caddy := which("caddy"); caddy != "" && t.now-t.vs.n("caddy_t", 0) >= every*60-5 {
			os.WriteFile(ref, nil, 0o644) // its mtime is the time of this validation
			t.vs.set("caddy_t", decimal.Itoa(t.now))
			// caddy may write its local CA while validating: into the tmpfs, as home is read-only here
			rd := t.w.RunDir
			env := append([]string{"HOME=" + rd, "XDG_DATA_HOME=" + rd + "/caddy", "XDG_CONFIG_HOME=" + rd + "/caddy"}, cmdEnv...)
			var out strings.Builder
			_, err := t.w.Env.Run.Output(t.ctx, run.Cmd{
				Argv: []string{caddy, "validate", "--config", filepath.Join(t.w.Caddy, "Caddyfile"), "--adapter", "caddyfile"},
				Env:  env, Stdout: &out, Timeout: 30 * time.Second,
			})
			if err == nil {
				t.vs.set("caddy_bad", "")
			} else {
				msg := caddyError(out.String() + "\n" + err.Error())
				if msg == "" {
					msg = "caddy validate failed"
				}
				t.vs.set("caddy_bad", clean(msg))
			}
		}
	}
	if why := t.vs.get("caddy_bad"); why != "" {
		t.sample("_host.caddy_config", "_host", "caddy_config", bad,
			"the Caddy config on disk is invalid (the next reload or restart fails): "+why, 1)
	} else {
		t.sample("_host.caddy_config", "_host", "caddy_config", ok, "", 1)
	}
}

// caddyChanged: no validation yet, or something under /etc/caddy (two levels) is newer.
func (t *tick) caddyChanged(ref string) bool {
	rf, err := os.Stat(ref)
	if err != nil {
		return true
	}
	c := t.w.Caddy
	paths := []string{c}
	l1, _ := filepath.Glob(filepath.Join(c, "*"))
	l2, _ := filepath.Glob(filepath.Join(c, "*", "*"))
	paths = append(append(paths, l1...), l2...)
	for _, p := range paths {
		if strings.HasPrefix(filepath.Base(p), ".") && p != c {
			continue // (a shell glob skips dot files)
		}
		if fi, err := os.Stat(p); err == nil && fi.ModTime().After(rf.ModTime()) {
			return true
		}
	}
	return false
}

var (
	msgRe = regexp.MustCompile(`.*"msg":"([^"]*)".*`)
	errRe = regexp.MustCompile(`.*"error":"([^"]*)".*`)
)

// caddyError is the first line that mentions an error; from Caddy's JSON log its "msg" (or
// "error"), from older versions the plain line.
func caddyError(out string) string {
	for l := range strings.SplitSeq(out, "\n") {
		if !strings.Contains(strings.ToLower(l), "error") {
			continue
		}
		if m := msgRe.FindStringSubmatch(l); m != nil {
			return m[1]
		}
		if m := errRe.FindStringSubmatch(l); m != nil {
			return m[1]
		}
		return l
	}
	return ""
}
