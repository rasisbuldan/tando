package watch

import (
	"strings"

	"tando/srv/internal/decimal"
)

// result of one check for one sample: bad, ok, or hold (not evaluated this run: the state is
// left alone, e.g. while the app deploys or its unit is down).
type result int

const (
	hold result = iota
	ok
	bad
)

// display is the app as the user sees it: "_host" is "host".
func display(a string) string {
	if a == "_host" {
		return "host"
	}
	return a
}

// settingsApp is the app whose settings apply: none for the host.
func settingsApp(a string) string {
	if a == "_host" {
		return ""
	}
	return a
}

// sameSample: two runs within the same sample period (sample_seconds, a wall-clock minute by
// default). A streak ("fire after N samples in a row", "resolve after N good ones", the liveness
// count) counts periods, not runs: some paths run twice in a minute (tandod's tick and one asked
// for, the agent's run after a rollback, a degraded daemon's retry). The test suites, which drive
// runs seconds apart to stand for minutes, set sample_seconds=0: every run counts.
func (t *tick) sameSample(a, b int64) bool {
	p := t.cfg.num("sample_seconds", "")
	return p > 0 && a/p == b/p
}

// sample moves the (app, check) under key k through its states:
//
//	ok -> pending      a bad sample, fewer than need of them in a row
//	pending -> firing  the need-th bad sample (samples more than 5 min apart do not add up)
//	firing -> ok       resolve_after good samples in a row (health_recover of the app for health)
//	pending -> ok      one good sample
//
// A firing alert keeps the detail it fired with. Firing is an event (history, incident) and, unless
// the app is silenced, counts towards flapping. What is sent is decided later (reconcile).
func (t *tick) sample(k, a, c string, r result, det string, need int64) {
	if r == hold {
		return
	}
	W := t.st
	st := W.or(k+".st", "ok")
	if r == bad {
		switch st {
		case "ok", "pending":
			n, lt := W.n(k+".n", 0), W.n(k+".lt", 0)
			if st == "pending" && t.sameSample(t.now, lt) {
				// a second run in the same minute (tandod's tick and one asked for, the agent's
				// run after a rollback): it re-evaluates, it does not count a second sample
				W.set(k+".det", det)
				return
			}
			if t.now-lt > 300 {
				n = 0 // samples more than 5 min apart do not add up
			}
			n++
			if n >= need {
				W.set(k+".st", "firing")
				W.set(k+".since", W.or(k+".since", decimal.Itoa(t.now)))
				W.set(k+".det", det)
				W.del(k+".n", k+".lt", k+".okn", k+".okt")
				t.event("fire", a, c, det)
				if !t.silenced(display(a)) {
					t.flapNote(k, a, c)
				}
			} else {
				W.set(k+".st", "pending")
				W.set(k+".n", decimal.Itoa(n))
				W.set(k+".lt", decimal.Itoa(t.now))
				if st == "ok" {
					W.set(k+".since", decimal.Itoa(t.now))
				}
				W.set(k+".det", det)
			}
		case "firing":
			W.del(k+".okn", k+".okt")
		}
		return
	}
	switch st {
	case "pending":
		W.del(k+".st", k+".n", k+".lt", k+".since", k+".det")
	case "firing":
		ra := t.cfg.num("resolve_after", settingsApp(a))
		if r, ok := t.recover[k]; ok {
			ra = r // health_recover of the app (tando.conf)
		}
		if okt := W.get(k + ".okt"); okt != "" && t.sameSample(t.now, W.n(k+".okt", 0)) {
			return // (counted this minute already)
		}
		n := W.n(k+".okn", 0) + 1
		W.set(k+".okt", decimal.Itoa(t.now))
		if n >= ra {
			t.resolved[k] = "after " + dur(t.now-W.n(k+".since", t.now)) + " (was: " + W.get(k+".det") + ")"
			t.event("resolve", a, c, t.resolved[k])
			W.set(k+".st", "ok")
			W.del(k+".okn", k+".okt", k+".since", k+".det")
		} else {
			W.set(k+".okn", decimal.Itoa(n))
		}
	}
}

// flapNote remembers firing times; flap_max firings within flap_window make the check
// "flapping": one notice, then nothing is sent for it until it has been quiet for flap_window.
func (t *tick) flapNote(k, a, c string) {
	W := t.st
	sa := settingsApp(a)
	mx, win := t.cfg.num("flap_max", sa), t.cfg.num("flap_window", sa)
	var keep []string
	for _, x := range append(splitList(W.get(k+".fl")), decimal.Itoa(t.now)) {
		if t.now-num(x, 0) < win*60 {
			keep = append(keep, x)
		}
	}
	W.set(k+".fl", strings.Join(keep, ","))
	if int64(len(keep)) >= mx && W.or(k+".flap", "0") != "1" {
		W.set(k+".flap", "1")
		t.event("flap", a, c, "fired "+decimal.Itoa(int64(len(keep)))+" times within "+decimal.Itoa(win)+" min; notifications for it pause until it is stable")
	}
}

// silenced: the app (as displayed: "host" for host checks) or everything is silenced now.
func (t *tick) silenced(a string) bool {
	return t.st.n("_sil."+a, 0) > t.now || t.st.n("_sil.all", 0) > t.now
}

// splitList splits "1,2,3" (empty: nothing), as bash's ${x//,/ } word splitting does.
func splitList(s string) []string {
	var res []string
	for f := range strings.SplitSeq(s, ",") {
		if f != "" {
			res = append(res, f)
		}
	}
	return res
}

// lastOf is the part after the last comma (${fl##*,}).
func lastOf(s string) string {
	if i := strings.LastIndexByte(s, ','); i >= 0 {
		return s[i+1:]
	}
	return s
}
