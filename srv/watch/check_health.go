package watch

import (
	"regexp"
	"strings"
	"time"

	"tando/srv/internal/decimal"
	"tando/srv/internal/run"
)

// queueProbe queues the app's health probe (all apps are probed at once below), through Caddy
// at the app's link, as a visitor would reach it.
func queueProbe(t *tick, a *appTick) {
	if !t.cfg.on("health", a.name) || a.hold || !t.caddyUp {
		return // (held: the state is left alone)
	}
	scheme := "https://"
	if or(t.host["tls"], "off") == "off" {
		scheme = "http://"
	}
	a.probeURL = scheme + t.site(a.name) + a.conf["path"] + or(a.conf["health"], "/")
}

// site is the app's link host: <app>.<apps_domain>.
func (t *tick) site(a string) string { return a + "." + or(t.host["apps_domain"], "localhost") }

var (
	expectRe = regexp.MustCompile(`^[1-5]([0-9]{2}|xx)$`)
	threeRe  = regexp.MustCompile(`^[0-9]{3}$`)
	smallRe  = regexp.MustCompile(`^[1-9][0-9]?$`)
)

// checkHealth probes every queued app at once and classifies each answer, so that an alert
// says what kind of trouble it is:
//
//	unhealthy  it answers, but not what health_expect wants (status, text), or Caddy gets nothing
//	           from its port (502/504)
//	slow       no answer within health_timeout
//	saturated  Caddy answered 503 "busy": more requests at once than max_requests/max_conns
//	down       Caddy answered 503 "unavailable": no process to send it to
func checkHealth(t *tick) {
	var reqs []probeReq
	var queued []*appTick
	for _, a := range t.apps {
		if a.probeURL != "" {
			reqs = append(reqs, probeReq{a.probeURL})
			queued = append(queued, a)
		}
	}
	if len(reqs) == 0 {
		return
	}
	to := t.cfg.num("health_timeout", "")
	res := t.w.Probe.Probe(t.ctx, reqs, time.Duration(to)*time.Second)
	for i, a := range queued {
		r := res[i]
		k := a.key("health")
		// health_expect = [status|Nxx] [text]; the default: any 2xx or 3xx
		hx := a.conf["health_expect"]
		exp, txt, _ := strings.Cut(hx, " ")
		if !expectRe.MatchString(exp) {
			exp, txt = "", hx
		}
		need := t.cfg.num("health_fails", a.name)
		if hf := a.conf["health_fails"]; smallRe.MatchString(hf) {
			need = num(hf, need)
		}
		if hr := a.conf["health_recover"]; smallRe.MatchString(hr) {
			t.recover[k] = num(hr, 0)
		}
		code := itoa3(r.code)
		cls := "ok"
		if (exp == "" && code[0] != '2' && code[0] != '3') || (strings.HasSuffix(exp, "xx") && code[0] != exp[0]) ||
			(threeRe.MatchString(exp) && code != exp) {
			cls = "bad"
		}
		if cls == "ok" && txt != "" && !strings.Contains(r.body, txt) {
			cls = "notext"
		}
		ms := decimal.Itoa(r.ms)
		if cls == "ok" { // (judged by the status and the text, as curl's: a body cut by the timeout still counts)
			t.sample(k, a.name, "health", ok, "", need)
			t.st.del(a.name+".live.n", a.name+".live.lt")
			a.class = "ok " + ms
			continue
		}
		var det string
		switch {
		case r.exit == 28:
			cls, det = "slow", "slow: no answer within "+decimal.Itoa(to)+" s (health_timeout)"
		case r.exit == 0 && code == "503":
			switch {
			case strings.Contains(r.body, "is busy:"):
				cls, det = "saturated", "saturated: Caddy answered 503 busy (more requests at once than max_requests/max_conns)"
			case strings.Contains(r.body, "is unavailable"):
				cls, det = "down", "down: Caddy answered 503, no process to send it to"
			default:
				cls, det = "unhealthy", "unhealthy: answered HTTP 503"
			}
		case r.exit == 0 && (code == "502" || code == "504"):
			cls, det = "unhealthy", "unhealthy: Caddy got no answer from the app's port (HTTP "+code+")"
		case r.exit == 0:
			if cls == "notext" {
				det = "unhealthy: answered HTTP " + code + " without \"" + clean(cut(txt, 60)) + "\""
			} else {
				det = "unhealthy: answered HTTP " + code + ", expected " + or(exp, "2xx/3xx")
			}
			cls = "unhealthy"
		case r.exit == 7:
			cls, det = "unhealthy", "unhealthy: connection refused"
		case r.exit == 52:
			cls, det = "unhealthy", "unhealthy: empty reply"
		default:
			cls, det = "unhealthy", "unhealthy: probe failed (curl error "+decimal.Itoa(int64(r.exit))+")"
		}
		a.class = cls + " " + ms
		j := t.st.n(k+".n", 0) + 1
		_, rest, _ := strings.Cut(a.probeURL, "//")
		t.sample(k, a.name, "health", bad, det+"; "+rest+" ("+decimal.Itoa(j)+" in a row)", need)
		t.liveness(a, det)
	}
}

// itoa3 is an HTTP status as curl's %{http_code} prints it: three digits, 000 for none.
func itoa3(c int) string {
	if c <= 0 || c > 999 {
		return "000"
	}
	s := decimal.Itoa(int64(c))
	for len(s) < 3 {
		s = "0" + s
	}
	return s
}

// liveness: an app whose unit runs but that failed `liveness` health probes in a row (a process
// thrashing at its memory cap, a deadlock: systemd sees nothing wrong) is restarted through the
// agent (its lock, the Caddy site, the health check and the audit line), in a unit of its own so
// this run does not wait. At most 3 restarts within an hour; after that only the health alert (a
// release that is broken for good is not restarted every few minutes forever).
func (t *tick) liveness(a *appTick, det string) {
	lim := t.cfg.num("liveness", a.name)
	if lim <= 0 {
		return
	}
	if rec := a.conf["recipe"]; rec == "" || rec == "static" {
		return
	}
	k := a.name + ".live"
	if lt := t.st.get(k + ".lt"); lt != "" && t.sameSample(t.now, t.st.n(k+".lt", 0)) {
		return // a second run in this minute: failed probes count once a minute (machine.go)
	}
	if t.unitState("tando-"+a.name+".service") != "active" {
		t.st.del(k+".n", k+".lt")
		return
	}
	n := t.st.n(k+".n", 0) + 1
	t.st.set(k+".lt", decimal.Itoa(t.now))
	if n < lim {
		t.st.set(k+".n", decimal.Itoa(n))
		return
	}
	t.st.del(k + ".n")
	// a saturated app is not a hung one: Caddy sheds requests over its limits (503 busy) and the
	// probe through Caddy waits behind them. Asked directly on its port, a working app still
	// answers (any status) within 20 s; only one that does not is restarted
	if port := a.conf["port"]; decimal.IsDigits(port) {
		if c := t.w.Probe.Direct(t.ctx, "http://127.0.0.1:"+port+or(a.conf["path"]+a.conf["health"], "/")); c >= 100 && c <= 599 {
			return
		}
	}
	t0, r := t.st.n(k+".t0", 0), t.st.n(k+".r", 0)
	if t.now-t0 > 3600 || t.now < t0 { // ("3 an hour", wall time; a clock stepped back starts the hour again)
		t0, r = t.now, 0
		t.st.del(k + ".gaveup")
	}
	if r >= 3 {
		if t.st.get(k+".gaveup") != "" {
			return
		}
		t.st.set(k+".gaveup", decimal.Itoa(t.now))
		t.event("restart", a.name, "health", det+", "+decimal.Itoa(n)+" checks in a row while its unit runs; tando-watch restarted it 3 times this hour and stops now: tando logs -a "+a.name+", tando restart -a "+a.name)
		return
	}
	t.st.set(k+".t0", decimal.Itoa(t0))
	t.st.set(k+".r", decimal.Itoa(r+1))
	t.w.Env.Run.Output(t.ctx, run.Cmd{Argv: []string{"systemd-run", "--quiet", "--collect", "--no-block",
		"--unit=tando-" + a.name + "-liveness-" + decimal.Itoa(t.now), "-p", "Description=tando-watch: restart " + a.name + " (unresponsive)",
		t.w.bin("tando-agent"), "restart", a.name}, Env: cmdEnv, Timeout: 20 * time.Second})
	t.event("restart", a.name, "health", det+", "+decimal.Itoa(n)+" checks in a row while its unit runs: restarted by tando-watch ("+decimal.Itoa(r+1)+" of at most 3 this hour)")
}

// unitState asks systemd for one unit's ActiveState now ("" when it does not answer).
func (t *tick) unitState(unit string) string {
	out, err := t.w.Env.Run.Output(t.ctx, run.Cmd{Argv: []string{"systemctl", "show", "-P", "ActiveState", unit}, Env: cmdEnv, Timeout: 20 * time.Second})
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// checkTLS: the certificate of the app's link, as Caddy serves it, every tls_every minutes.
// tls=auto: it must also verify against the system's CAs; tls=internal: Caddy's own CA, only
// the dates count.
func checkTLS(t *tick, a *appTick) {
	tlsMode := or(t.host["tls"], "off")
	if tlsMode == "off" || !t.cfg.on("tls", a.name) || t.now-t.vs.n("tls."+a.name, 0) < t.cfg.num("tls_every", a.name)*60 {
		return
	}
	defer t.vs.set("tls."+a.name, decimal.Itoa(t.now))
	k := a.key("tls")
	site := t.site(a.name)
	nb, na, err := t.w.Certs.Cert(t.ctx, site, tlsMode != "internal")
	switch {
	case err == errNoVerify:
		t.sample(k, a.name, "tls", bad, "the certificate for "+site+" does not verify (curl error 60)", 2)
		return
	case err != nil:
		t.sample(k, a.name, "tls", bad, "no certificate could be read for "+site, 2)
		return
	}
	ns, ne := nb.Unix(), na.Unix()
	if ne <= 0 {
		return
	}
	pct := t.cfg.num("tls_pct", a.name)
	switch {
	case ne <= t.now:
		t.sample(k, a.name, "tls", bad, "certificate for "+site+" expired "+dur(t.now-ne)+" ago", 1)
	case ns > 0 && ne > ns && (ne-t.now)*100 < (ne-ns)*pct:
		t.sample(k, a.name, "tls", bad, "certificate for "+site+" expires in "+dur(ne-t.now)+" (not renewed)", 1)
	default:
		t.sample(k, a.name, "tls", ok, "", 1)
	}
}
