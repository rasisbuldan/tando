package dash

import (
	"net/http"
	"time"
)

// The app pages' reads (M5): jobs, requests, errors, env names, env log, alerts, history. Each
// is one exact argv (allow.go), cached 60 s per (endpoint, host, app, range) with single flight,
// answered as {host, app, ran_at, cached, next_poll_s, data} with data the CLI's JSON as it is.
// They run in "/": a tando.conf in tando-dash's own folder never picks the app or the server.

type appRead1 struct {
	needApp bool
	rng     bool // requests: range=1h|24h|7d (default 1h), the CLI's --since
	argv    func(host, app, rng string) []string
}

var appReads = map[string]appRead1{
	"/api/jobs": {needApp: true, argv: func(h, a, _ string) []string { return []string{"jobs", "ls", a, "--json", "-H", h} }},
	"/api/requests": {needApp: true, rng: true, argv: func(h, a, r string) []string {
		return []string{"requests", "summary", a, "--json", "-H", h, "--since", r}
	}},
	"/api/errors":   {needApp: true, argv: func(h, a, _ string) []string { return []string{"errors", a, "--json", "-H", h} }},
	"/api/envnames": {needApp: true, argv: func(h, a, _ string) []string { return []string{"env", "ls", a, "--names", "--json", "-H", h} }},
	"/api/envlog":   {needApp: true, argv: func(h, a, _ string) []string { return []string{"env", "log", "-a", a, "--json", "-H", h} }},
	"/api/alerts":   {argv: func(h, _, _ string) []string { return []string{"alerts", "--json", "-H", h} }},
	"/api/history":  {argv: func(h, _, _ string) []string { return []string{"history", "--json", "-H", h} }},
}

func (s *Server) appRead(w http.ResponseWriter, r *http.Request, d appRead1) {
	q := r.URL.Query()
	host, app, rng := q.Get("host"), q.Get("app"), q.Get("range")
	if !ValidHost(host) {
		apiErr(w, 400, "bad_request", "host: letters, digits, . _ -")
		return
	}
	if d.needApp && !ValidApp(app) {
		apiErr(w, 400, "bad_request", "app: a-z, 0-9, -; 2-24 characters")
		return
	}
	if !d.needApp && app != "" {
		apiErr(w, 400, "bad_request", "this takes no app")
		return
	}
	if d.rng {
		if rng == "" {
			rng = "1h"
		}
		if !ValidRange(rng) {
			apiErr(w, 400, "bad_request", "range: 1h, 24h or 7d")
			return
		}
	} else if rng != "" {
		apiErr(w, 400, "bad_request", "this takes no range")
		return
	}
	if !s.knownHost(host) {
		apiErr(w, 404, "no_host", "no host named "+host+" (tando host ls)")
		return
	}
	argv := d.argv(host, app, rng)
	key := r.URL.Path + "\x00" + host + "\x00" + app + "\x00" + rng
	e, cached, err := s.more.get(r.Context(), s.base, key, s.cfg.AppReadTTL, s.cfg.ReadTimeout, s.cfg.Now, s.jsonRunIn("/", host, argv))
	if err != nil && r.Context().Err() != nil {
		return
	}
	next := int((s.cfg.AppReadTTL - s.cfg.Now().Sub(e.at)) / time.Second)
	if p := s.pollHint(r); next < p {
		next = p
	}
	body := map[string]any{"host": host, "ran_at": e.at.UTC().Format(time.RFC3339), "cached": cached, "next_poll_s": next}
	if d.needApp {
		body["app"] = app
	}
	if d.rng {
		body["range"] = rng
	}
	if err != nil {
		ae := cliErr(err)
		body["error"] = ae
		writeJSON(w, ae.Status, body)
		return
	}
	body["data"] = e.data
	writeJSON(w, 200, body)
}
