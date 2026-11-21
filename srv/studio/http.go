package studio

import (
	"bufio"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// CSP: the page's own three files and nothing else; no inline script or style, no plugin, no
// frame, no form target; Trusted Types make Chromium refuse any HTML sink (the page builds every
// node with textContent: database content is hostile).
const csp = "default-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; object-src 'none'; require-trusted-types-for 'script'"

func headers(h http.Header) {
	h.Set("Content-Security-Policy", csp)
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("Cache-Control", "no-store")
	h.Set("Cross-Origin-Opener-Policy", "same-origin")
	h.Set("Cross-Origin-Resource-Policy", "same-origin")
	h.Set("X-Frame-Options", "DENY")
}

// apiErr: an error that is not SQL
func apiErr(w http.ResponseWriter, status int, code, msg string) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	bw := bufio.NewWriter(w)
	j := &jw{w: bw}
	j.obj().k("error").obj().k("code").s(code).k("message").s(msg).end().end()
	bw.WriteByte('\n')
	bw.Flush()
}

// hostOK: the Host the page must come with: 127.0.0.1, localhost or [::1], and the laptop's
// port the studio was started for (DNS rebinding: a name that resolves to 127.0.0.1 carries
// that name; a trailing dot, another port or no port are refused too)
func (s *Studio) hostOK(h string) bool {
	p := ":" + strconv.Itoa(s.cfg.Port)
	return h == "127.0.0.1"+p || h == "localhost"+p || h == "[::1]"+p
}

// precheck: the checks every request passes before its route, the same in the per-app studio
// and in the service's front (service.go): Host (hostOK), Origin, Sec-Fetch-Site, no preflight,
// GET or POST with a JSON body of at most MaxBody for the API. false: answered already.
func precheck(w http.ResponseWriter, r *http.Request, hostOK func(string) bool, port string) bool {
	headers(w.Header())
	if !hostOK(r.Host) {
		apiErr(w, 403, "host", "this page is only served as http://127.0.0.1:"+port)
		return false
	}
	if o := r.Header.Get("Origin"); o != "" && o != "http://"+r.Host {
		apiErr(w, 403, "origin", "requests from another site are refused")
		return false
	}
	// (the page itself may be reached by a link on another site, a web terminal or a chat page:
	// a top-level GET of a static file, which holds no data; the key is in the link's fragment,
	// never sent, and the page cannot be framed (X-Frame-Options) or reached by its opener (COOP).
	// Every /api/ request, and anything that is not a plain navigation, stays same-origin only.)
	nav := r.Method == http.MethodGet && !strings.HasPrefix(r.URL.Path, "/api/") &&
		r.Header.Get("Sec-Fetch-Mode") == "navigate" && r.Header.Get("Sec-Fetch-Dest") == "document"
	if f := r.Header.Get("Sec-Fetch-Site"); f != "" && f != "same-origin" && f != "none" && !nav {
		apiErr(w, 403, "origin", "requests from another site are refused")
		return false
	}
	if r.Method == http.MethodOptions {
		apiErr(w, 405, "bad_request", "no cross-origin requests")
		return false
	}
	if !strings.HasPrefix(r.URL.Path, "/api/") {
		return true
	}
	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		apiErr(w, 405, "bad_request", "GET or POST")
		return false
	}
	if r.Method == http.MethodPost {
		if ct := r.Header.Get("Content-Type"); ct != "application/json" && !strings.HasPrefix(ct, "application/json;") {
			apiErr(w, 415, "bad_request", "the body must be application/json")
			return false
		}
		r.Body = http.MaxBytesReader(w, r.Body, MaxBody)
	}
	return true
}

// ServeHTTP: the checks every request passes, then the route.
func (s *Studio) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if !precheck(w, r, s.hostOK, strconv.Itoa(s.cfg.Port)) {
		return
	}
	path := r.URL.Path
	if !strings.HasPrefix(path, "/api/") {
		s.serveStatic(w, r)
		return
	}
	if path == "/api/session" {
		s.session(w, r)
		return
	}
	a := r.Header.Get("Authorization")
	tok, ok := strings.CutPrefix(a, "Bearer ")
	if !ok || subtle.ConstantTimeCompare([]byte(tok), []byte(s.token)) != 1 {
		apiErr(w, 401, "auth", "this studio session has ended or the page has no key: run tando db studio again")
		return
	}
	s.life.touch(s.cfg.Now())
	switch path {
	case "/api/info":
		s.info(w)
	case "/api/ping":
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte("{\"ok\":true}\n"))
	case "/api/end":
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte("{\"ok\":true}\n"))
		s.End("end")
	case "/api/cancel":
		var q struct{ ID string }
		if !decode(w, r, &q) {
			return
		}
		ok := s.c.cancel(q.ID)
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, "{\"cancelled\":%t}\n", ok)
	case "/api/tables":
		s.tables(w, r)
	case "/api/table":
		s.table(w, r)
	case "/api/rows":
		s.rows(w, r)
	case "/api/query":
		s.query(w, r)
	default:
		apiErr(w, 404, "not_found", "no such endpoint")
	}
}

func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	if r.Method != http.MethodPost {
		apiErr(w, 405, "bad_request", "POST")
		return false
	}
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if err := d.Decode(v); err != nil {
		var mb *http.MaxBytesError
		if errors.As(err, &mb) {
			apiErr(w, 413, "too_large", "the request is too large")
		} else {
			apiErr(w, 400, "bad_request", "bad request body")
		}
		return false
	}
	return true
}

// session: the one-time code of the URL for the bearer token. The URL is worth nothing after
// its first use (or after a minute): browser history, open's argv and the client's output may
// keep it.
func (s *Studio) session(w http.ResponseWriter, r *http.Request) {
	var q struct{ Code string }
	if !decode(w, r, &q) {
		return
	}
	fresh := s.cfg.Now().Sub(s.codeAt) <= CodeTTL
	if subtle.ConstantTimeCompare([]byte(q.Code), []byte(s.code)) != 1 || !fresh || !s.codeUse.CompareAndSwap(false, true) {
		apiErr(w, 401, "auth", "this link was already used or has expired: run tando db studio again")
		return
	}
	s.life.touch(s.cfg.Now())
	w.Header().Set("Content-Type", "application/json")
	bw := bufio.NewWriter(w)
	(&jw{w: bw}).obj().k("token").s(s.token).end()
	bw.Flush()
}

func (s *Studio) info(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	bw := bufio.NewWriter(w)
	j := &jw{w: bw}
	j.obj().k("app").s(s.cfg.App).k("host").s(s.cfg.Host).k("role").s(s.cfg.Role).k("db").s(s.cfg.Database).
		k("mode").s("ro").k("pg_version").s(s.pgver).k("idle_s").i(int64(s.cfg.Idle / time.Second)).
		k("hkey").s(s.hkey)
	j.k("limits").obj().k("rows").i(DefaultRows).k("max_rows").i(MaxRows).k("cell_bytes").i(CellBytes).
		k("resp_bytes").i(RespBytes).k("timeout_ms").i(s.cfg.StmtLimit.Milliseconds()).end()
	j.end()
	bw.Flush()
}

// dbFail answers a request that could not use the database
func (s *Studio) dbFail(w http.ResponseWriter, err error) {
	if errors.Is(err, errBusy) {
		apiErr(w, 409, "busy", "a query is still running (Stop cancels it)")
		return
	}
	if errors.Is(err, context.Canceled) {
		return
	}
	fmt.Fprintf(s.cfg.Log, "tando-studio: %v\n", err)
	apiErr(w, 503, "db_unavailable", err.Error())
}
