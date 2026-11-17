package watch

import (
	"path/filepath"

	"tando/srv/internal/decimal"
	"tando/srv/internal/kvfile"
)

// checkStuck: while an activation runs, and for deploy_grace after it, the app is not checked
// (held), except for "stuck". An activation or rollback holds the app's lock; a phase other
// than idle with the lock free means the activation died (SIGKILL, full disk): then the app is
// checked again, and two such samples in a row are "stuck" whatever its age.
func checkStuck(t *tick, a *appTick) {
	k := a.key("stuck")
	phase := or(a.state["phase"], "idle")
	if phase == "idle" {
		if t.st.get(k+".st") != "" {
			t.sample(k, a.name, "stuck", ok, "", 1)
		}
		if dg := t.vs.get("dg." + a.name); dg != "" && t.now-num(dg, 0) < t.cfg.num("deploy_grace", a.name) {
			a.hold = true
		}
		return
	}
	act, _ := kvfile.Load(filepath.Join(t.w.appDir(a.name), "activation"))
	alive := lockHeld(filepath.Join(t.w.appDir(a.name), "lock"))
	if alive {
		t.vs.set("dg."+a.name, decimal.Itoa(t.now))
		a.hold = true
	}
	if !t.cfg.on("stuck", a.name) {
		return
	}
	target := or(a.state["target"], "?")
	started := num(or(act["started"], decimal.Itoa(t.now)), t.now)
	switch {
	case !alive:
		t.sample(k, a.name, "stuck", bad, "activation of "+target+" died in phase "+phase+
			" (result "+or(act["result"], "?")+"; nothing holds the app's lock)", 2)
	case t.now-started > t.cfg.num("stuck_min", a.name)*60:
		t.sample(k, a.name, "stuck", bad, "activation of "+target+" in phase "+phase+" for "+dur(t.now-started), 1)
	default:
		t.sample(k, a.name, "stuck", ok, "", 1)
	}
}
