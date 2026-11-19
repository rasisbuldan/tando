package watch

import (
	"strings"

	"tando/srv/internal/decimal"
)

// message is one line of a notification: firing, resolved, still firing, flap, reboot, rollback,
// restart, newerror, log (a line of the app's log under a crash, with include_log_lines=on).
type message struct {
	kind, app, check, detail string
	since                    int64
}

// line is the message as a queue file line: five tab-separated fields (a tab or newline in the
// detail would move the fields, so they become spaces).
func (m message) line() string {
	d := strings.NewReplacer("\t", " ", "\n", " ").Replace(m.detail)
	return m.kind + "\t" + m.app + "\t" + m.check + "\t" + d + "\t" + decimal.Itoa(m.since) + "\n"
}

// reconcile decides what to tell the notifiers. The last notified state (ns) follows the true
// state unless the app is silenced or the check is flapping; a reminder goes out every
// remind_hours while it keeps firing. A check that was turned off resolves (once, if it had been
// sent) instead of staying stuck. A firing check that failed anew this run (t.again: a job's next
// failed run) is told once more. An ok check with nothing left to remember leaves the state.
func (t *tick) reconcile() {
	W := t.st
	for _, key := range W.keys() {
		k, isSt := strings.CutSuffix(key, ".st")
		if !isSt || !W.has(key) {
			continue
		}
		a, c, _ := strings.Cut(k, ".")
		sw, sa := c, a
		if strings.HasPrefix(c, "job.") {
			sw = "job" // every job of the app is one switch: job=off, <app>.job=off
		}
		if a == "_host" {
			sa = ""
			if c == "memory" || c == "oom" {
				sw = "host_" + c
			}
		}
		if W.get(key) != "ok" && !t.cfg.on(sw, sa) {
			t.resolved[k] = "the check was turned off"
			if W.get(key) == "firing" {
				t.event("resolve", a, c, t.resolved[k])
			}
			W.set(key, "ok")
			W.del(k+".n", k+".lt", k+".okn", k+".okt", k+".since", k+".det", k+".flap")
		}
		st, ns, flap := W.get(key), W.or(k+".ns", "ok"), W.or(k+".flap", "0")
		if st == "pending" {
			continue
		}
		if flap == "1" {
			last := num(lastOf(W.get(k+".fl")), 0)
			if t.now-last >= t.cfg.num("flap_window", sa)*60 {
				W.set(k+".flap", "0")
			} else {
				continue
			}
		}
		da := display(a)
		if t.silenced(da) {
			continue
		}
		switch {
		case st == "firing" && ns != "firing":
			t.out = append(t.out, message{"firing", da, c, W.get(k + ".det"), W.n(k+".since", t.now)})
			W.set(k+".ns", "firing")
			W.set(k+".nt", decimal.Itoa(t.now))
		case st == "ok" && ns == "firing":
			t.out = append(t.out, message{"resolved", da, c, t.resolved[k], t.now})
			W.del(k+".ns", k+".nt")
		case st == "firing" && t.again[k]:
			// it failed anew while firing (a job's next failed run): one more message, with the new detail
			t.out = append(t.out, message{"firing", da, c, W.get(k + ".det"), W.n(k+".since", t.now)})
			W.set(k+".nt", decimal.Itoa(t.now))
		case st == "firing":
			rem := t.cfg.num("remind_hours", sa)
			if rem > 0 && t.now-W.n(k+".nt", 0) >= rem*3600 {
				since := W.n(k+".since", t.now)
				d := W.get(k+".det") + " (since " + dur(t.now-since) + ")"
				t.out = append(t.out, message{"still firing", da, c, d, since})
				W.set(k+".nt", decimal.Itoa(t.now))
			}
		}
		if st == "ok" && W.get(k+".ns") == "" && W.or(k+".flap", "0") == "0" {
			fl := W.get(k + ".fl")
			if fl == "" || t.now-num(lastOf(fl), 0) >= t.cfg.num("flap_window", sa)*60 {
				W.del(k+".st", k+".fl", k+".flap", k+".run")
			}
		}
	}
}
