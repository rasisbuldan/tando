package dash

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime/debug"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Config: what a Server needs; zero values get the defaults of New.
type Config struct {
	Port      int    // the port it listens on (Host header check)
	ConfigDir string // ~/.config/tando (TANDO_CONFIG_DIR)
	Runner    Runner // the tando CLI
	Now       func() time.Time
	Log       io.Writer
	CtlKey    string // the key of dash.lock: a second tando-dash asks for a new code with it
	Version   *Guard // the tando CLI version check; nil: none (tests)

	CodeTTL      time.Duration // one-time code of the opening link: 60 s
	SessionTTL   time.Duration // cookie: 30 days
	ConfirmTTL   time.Duration // confirm token: 60 s
	CacheTTL     time.Duration // snapshot cache: 10 s
	HostCareTTL  time.Duration // doctor, host status: 60 s
	ReadTimeout  time.Duration // one read run: 30 s
	WriteTimeout time.Duration // one write run: 30 min
	IdemTTL      time.Duration // idempotency records: 24 h
	PollVisible  int           // next_poll_s while visible: 15
	PollHidden   int           // next_poll_s off-screen: 60
	MaxBody      int64         // request body: 64 KB
	MaxCache     int           // cache entries: 256
	MaxIdem      int           // idempotency records: 500
	MaxInflight  int           // /api/ requests at once: 64
	MaxHosts     int           // hosts in the overview: 64
}

func (c *Config) defaults() {
	d := func(p *time.Duration, v time.Duration) {
		if *p == 0 {
			*p = v
		}
	}
	d(&c.CodeTTL, 60*time.Second)
	d(&c.SessionTTL, 30*24*time.Hour)
	d(&c.ConfirmTTL, 60*time.Second)
	d(&c.CacheTTL, 10*time.Second)
	d(&c.HostCareTTL, 60*time.Second)
	d(&c.ReadTimeout, 30*time.Second)
	d(&c.WriteTimeout, 30*time.Minute)
	d(&c.IdemTTL, 24*time.Hour)
	i := func(p *int, v int) {
		if *p == 0 {
			*p = v
		}
	}
	i(&c.PollVisible, 15)
	i(&c.PollHidden, 60)
	i(&c.MaxCache, 256)
	i(&c.MaxIdem, 500)
	i(&c.MaxInflight, 64)
	i(&c.MaxHosts, 64)
	if c.MaxBody == 0 {
		c.MaxBody = 64 << 10
	}
	if c.Now == nil {
		c.Now = time.Now
	}
	if c.Log == nil {
		c.Log = os.Stderr
	}
}

// Server: the HTTP handler of tando-dash
type Server struct {
	cfg      Config
	base     context.Context // reads; cancelled by Close (writes have their own)
	stop     context.CancelFunc
	sess     *sessions
	snaps    *cache
	care     *cache
	confirms *confirms
	idem     *idemStore
	writes   *writeLocks
	inflight atomic.Int64
	lastUse  atomic.Int64
	static   http.Handler
	wg       sync.WaitGroup // running writes
}

// New: a server; it loads the sessions and the idempotency records from ConfigDir
func New(cfg Config, static http.Handler) (*Server, error) {
	cfg.defaults()
	ctx, stop := context.WithCancel(context.Background())
	s := &Server{cfg: cfg, base: ctx, stop: stop, static: static}
	s.sess = newSessions(filepath.Join(cfg.ConfigDir, "cache", "dash-sessions.json"), cfg.Now)
	s.snaps = newCache(cfg.MaxCache, false)
	s.care = newCache(cfg.MaxCache, true)
	s.snaps.logw, s.care.logw = cfg.Log, cfg.Log
	s.confirms = newConfirms(cfg.Now)
	var err error
	s.idem, err = openIdem(filepath.Join(cfg.ConfigDir, "cache", "dash-idem.json"), filepath.Join(cfg.ConfigDir, "cache", "dash-ops"), cfg.MaxIdem, cfg.IdemTTL, cfg.Now)
	if err != nil {
		stop()
		return nil, err
	}
	s.writes = newWriteLocks()
	s.lastUse.Store(cfg.Now().UnixNano())
	return s, nil
}

// Close: the reads' children are killed; running writes are left alone (tando owns them)
func (s *Server) Close() { s.stop() }

// LastUse: when the last request came
func (s *Server) LastUse() time.Time { return time.Unix(0, s.lastUse.Load()) }

// WritesRunning: writes whose child has not ended
func (s *Server) WritesRunning() int { return s.writes.count() }

// NewCode: a one-time code for the opening link (main, and a second tando-dash)
func (s *Server) NewCode() string { return s.sess.newCode(s.cfg.CodeTTL) }

func (s *Server) logf(format string, a ...any) {
	fmt.Fprintf(s.cfg.Log, "tando-dash: "+format+"\n", a...)
}

// CSP of the brief: the page's own files only, Trusted Types, no inline anything
const CSP = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'; require-trusted-types-for 'script'"

func headers(h http.Header) {
	h.Set("Content-Security-Policy", CSP)
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("Cross-Origin-Opener-Policy", "same-origin")
	h.Set("Cross-Origin-Resource-Policy", "same-origin")
	h.Set("X-Frame-Options", "DENY")
}

// apiError: what every failed /api/ request answers: {"error":{"code","message"}}
type apiError struct {
	Status int    `json:"-"`
	Code   string `json:"code"`
	Msg    string `json:"message"`
	Extra  any    `json:"running,omitempty"`
}

func apiErr(w http.ResponseWriter, status int, code, msg string) {
	writeErr(w, &apiError{Status: status, Code: code, Msg: msg})
}

func writeErr(w http.ResponseWriter, e *apiError) {
	writeJSON(w, e.Status, map[string]any{"error": e})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(true)
	_ = enc.Encode(v)
}

// hostOK: exactly 127.0.0.1:<port> or localhost:<port> (DNS rebinding: another name, a
// trailing dot, another port or no port are refused)
func (s *Server) hostOK(h string) bool {
	p := ":" + strconv.Itoa(s.cfg.Port)
	return h == "127.0.0.1"+p || h == "localhost"+p
}

const sessionMsg = "Session ended. Open the dashboard again with tando-dash."

// ServeHTTP: the checks every request passes, then the route
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	defer func() {
		if v := recover(); v != nil {
			if v == http.ErrAbortHandler {
				panic(v)
			}
			s.logf("panic in %s %s: %v\n%s", r.Method, r.URL.Path, v, firstLines(string(debug.Stack()), 12))
			apiErr(w, 500, "internal", "tando-dash failed on this request; it keeps running")
		}
	}()
	headers(w.Header())
	if !s.hostOK(r.Host) {
		apiErr(w, 403, "host", "tando-dash is only served as http://127.0.0.1:"+strconv.Itoa(s.cfg.Port))
		return
	}
	if o := r.Header.Get("Origin"); o != "" && o != "http://"+r.Host {
		apiErr(w, 403, "origin", "requests from another site are refused")
		return
	}
	// a top-level navigation to a page (not /api/) may come from anywhere (a link): the page
	// holds no data; everything else is same-origin only
	nav := (r.Method == http.MethodGet || r.Method == http.MethodHead) && !strings.HasPrefix(r.URL.Path, "/api/") &&
		r.Header.Get("Sec-Fetch-Mode") == "navigate" && r.Header.Get("Sec-Fetch-Dest") == "document"
	if f := r.Header.Get("Sec-Fetch-Site"); f != "" && f != "same-origin" && f != "none" && !nav {
		apiErr(w, 403, "origin", "requests from another site are refused")
		return
	}
	if r.Method == http.MethodOptions {
		apiErr(w, 405, "method", "no cross-origin requests")
		return
	}
	if !strings.HasPrefix(r.URL.Path, "/api/") {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			apiErr(w, 405, "method", "GET")
			return
		}
		if r.URL.Path == "/open" {
			s.open(w, r)
			return
		}
		if s.static == nil {
			http.NotFound(w, r)
			return
		}
		s.static.ServeHTTP(w, r)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		apiErr(w, 405, "method", "GET or POST")
		return
	}
	if r.Method == http.MethodPost {
		if ct := r.Header.Get("Content-Type"); ct != "application/json" && !strings.HasPrefix(ct, "application/json;") {
			apiErr(w, 415, "content_type", "the body must be application/json")
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, s.cfg.MaxBody)
	}
	if n := s.inflight.Add(1); n > int64(s.cfg.MaxInflight) {
		s.inflight.Add(-1)
		w.Header().Set("Retry-After", "2")
		apiErr(w, 503, "busy", "tando-dash is busy; retry in a moment")
		return
	}
	defer s.inflight.Add(-1)
	if r.URL.Path == "/api/newcode" {
		s.newcode(w, r)
		return
	}
	if !s.sess.valid(r) {
		apiErr(w, 401, "session", sessionMsg)
		return
	}
	s.lastUse.Store(s.cfg.Now().UnixNano())
	if s.cfg.Version != nil {
		if err := s.cfg.Version.Check(r.Context()); err != nil {
			apiErr(w, 503, "update_tando", err.Error())
			return
		}
	}
	switch r.URL.Path {
	case "/api/ping":
		writeJSON(w, 200, map[string]any{"ok": true})
	case "/api/snapshot":
		s.snapshot(w, r)
	case "/api/overview":
		s.overview(w, r)
	case "/api/doctor":
		s.hostcare(w, r, "doctor")
	case "/api/hoststatus":
		s.hostcare(w, r, "hoststatus")
	case "/api/confirm":
		s.confirm(w, r)
	case "/api/action":
		if r.Method == http.MethodGet {
			s.actionStatus(w, r)
		} else {
			s.action(w, r)
		}
	default:
		apiErr(w, 404, "not_found", "no such endpoint")
	}
}

// decode: a POST's JSON body into v (unknown fields refused)
func decode(w http.ResponseWriter, r *http.Request, v any) ([]byte, bool) {
	if r.Method != http.MethodPost {
		apiErr(w, 405, "method", "POST")
		return nil, false
	}
	b, err := io.ReadAll(r.Body)
	if err != nil {
		var mb *http.MaxBytesError
		if errors.As(err, &mb) {
			apiErr(w, 413, "too_large", "the request is too large")
		} else {
			apiErr(w, 400, "bad_request", "could not read the request")
		}
		return nil, false
	}
	d := json.NewDecoder(strings.NewReader(string(b)))
	d.DisallowUnknownFields()
	if err := d.Decode(v); err != nil {
		apiErr(w, 400, "bad_request", "bad request body")
		return nil, false
	}
	return b, true
}

// newcode: a second tando-dash (or the menu bar's window) asks the running one for a fresh
// opening link, with the key of dash.lock (0600: only this user can read it)
func (s *Server) newcode(w http.ResponseWriter, r *http.Request) {
	k := r.Header.Get("X-Tando-Dash-Key")
	if s.cfg.CtlKey == "" || subtle.ConstantTimeCompare([]byte(k), []byte(s.cfg.CtlKey)) != 1 {
		apiErr(w, 401, "auth", "bad key")
		return
	}
	if r.Method != http.MethodPost {
		apiErr(w, 405, "method", "POST")
		return
	}
	s.lastUse.Store(s.cfg.Now().UnixNano())
	writeJSON(w, 200, map[string]any{"code": s.NewCode(), "pid": os.Getpid()})
}

// Hosts: the hosts tando knows (files of ConfigDir/hosts), valid names only, sorted
func (s *Server) Hosts() []string {
	ents, err := os.ReadDir(filepath.Join(s.cfg.ConfigDir, "hosts"))
	if err != nil {
		return nil
	}
	var hs []string
	for _, e := range ents {
		if e.Type().IsRegular() && ValidHost(e.Name()) {
			hs = append(hs, e.Name())
		}
	}
	sort.Strings(hs)
	if len(hs) > s.cfg.MaxHosts {
		hs = hs[:s.cfg.MaxHosts]
	}
	return hs
}

func (s *Server) knownHost(h string) bool {
	if !ValidHost(h) {
		return false
	}
	fi, err := os.Stat(filepath.Join(s.cfg.ConfigDir, "hosts", h))
	return err == nil && fi.Mode().IsRegular()
}

// run: the allowlist, then the runner
func (s *Server) run(ctx context.Context, r Req) (Result, error) {
	if _, err := Allowed(r.Argv); err != nil {
		return Result{}, err
	}
	return s.cfg.Runner.Run(ctx, r)
}

// cliErr: a run's error as an API error
func cliErr(err error) *apiError {
	var ce *CLIError
	switch {
	case errors.Is(err, ErrBusy):
		return &apiError{Status: 503, Code: "busy", Msg: err.Error()}
	case errors.Is(err, ErrRefused):
		return &apiError{Status: 403, Code: "refused", Msg: err.Error()}
	case errors.Is(err, errPanic):
		return &apiError{Status: 500, Code: "internal", Msg: err.Error()}
	case errors.Is(err, errBadOutput):
		return &apiError{Status: 502, Code: "bad_output", Msg: err.Error()}
	case errors.As(err, &ce):
		st := 502
		if ce.Code == "timeout" {
			st = 504
		}
		if strings.Contains(ce.Msg, "unknown command") {
			return &apiError{Status: 503, Code: "update_tando", Msg: "update tando: " + ce.Msg}
		}
		return &apiError{Status: st, Code: ce.Code, Msg: ce.Msg}
	case errors.Is(err, context.DeadlineExceeded):
		return &apiError{Status: 504, Code: "timeout", Msg: "tando did not answer in time"}
	case errors.Is(err, context.Canceled):
		return &apiError{Status: 499, Code: "cancelled", Msg: "cancelled"}
	}
	return &apiError{Status: 502, Code: "cli", Msg: err.Error()}
}
