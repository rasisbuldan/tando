package studio

// The always-on service (docs/STUDIO.md): one front per server, `tando-studio service`, root
// with CAP_SETUID and CAP_SETGID only, on unix sockets only. It holds the codes and the tokens,
// makes every check of a request that ServeHTTP makes (precheck: Host, Origin, Sec-Fetch-Site,
// JSON bodies), and forwards each API request to the helper of the app it names: the per-app
// studio of studio.go (`tando-studio serve --fd`), started on demand as the app's user, which
// alone holds the app's password and connection. The front never reaches PostgreSQL.

import (
	"bufio"
	"context"
	"crypto/subtle"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"tando/srv/internal/valid"
)

const (
	TokenIdle     = 12 * time.Hour    // a token unused this long is gone
	HelperIdle    = 120 * time.Second // a helper exits after this long without a request
	HelpersPerApp = 2
	HelpersAll    = 4
)

// SvcConfig: the service's paths and its two hooks (tests replace Spawn).
type SvcConfig struct {
	Root  string // /opt/tando: apps/<app>/app.conf
	Run   string // /run/tando-studio: ctl, u/<admin>/s, h/ (the helpers' sockets), lower/
	Log   io.Writer
	Now   func() time.Time
	Spawn func(h *Helper) error // start h: set Dial, Token, Stop and Done
}

// Service is the front.
type Service struct {
	cfg     SvcConfig
	probe   string
	static  map[string]asset
	mu      sync.Mutex
	codes   []*svcCode
	sess    []*svcSession
	helpers []*Helper
	lns     map[string]net.Listener // admin -> the socket of that admin
	srvs    []*http.Server
}

type svcCode struct {
	code, admin, app, host string
	port                   int
	at                     time.Time
}

type svcSession struct {
	id, token, admin, app, host string
	port                        int
	last                        time.Time
}

// Helper: one app's studio for one browser session.
type Helper struct {
	App, Host, Admin, Sess string
	Port                   int
	Dial                   func(ctx context.Context) (net.Conn, error)
	Token                  string
	Stop                   func()
	Done                   chan struct{}
	ready                  chan struct{}
	err                    error
	busy                   int
	last                   time.Time
	rp                     *httputil.ReverseProxy
}

// NewService: nothing is started; Listen* and Serve do that.
func NewService(cfg SvcConfig) *Service {
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.Log == nil {
		cfg.Log = io.Discard
	}
	return &Service{cfg: cfg, probe: rnd(8), static: assets(), lns: map[string]net.Listener{}}
}

// loopPort: the port of a Host the page may come with (127.0.0.1, localhost or [::1], a port;
// DNS rebinding: any other name, a trailing dot or no port is refused), 0 when it is not one
func loopPort(h string) int {
	for _, p := range []string{"127.0.0.1:", "localhost:", "[::1]:"} {
		if v, ok := strings.CutPrefix(h, p); ok {
			if n, ok := valid.Uint(v, 1024, 65535); ok {
				return int(n)
			}
		}
	}
	return 0
}

// ---- codes (the ctl socket) -------------------------------------------------------------------

var errNoDB = errors.New("this app has no database (database = postgres in its tando.conf, then tando up)")

// AppConf: a line of the app's app.conf ("" when absent)
func (v *Service) AppConf(app, key string) (string, bool) {
	b, err := os.ReadFile(filepath.Join(v.cfg.Root, "apps", app, "app.conf"))
	if err != nil {
		return "", false
	}
	for _, l := range strings.Split(string(b), "\n") {
		if x, ok := strings.CutPrefix(l, key+"="); ok {
			return x, true
		}
	}
	return "", true
}

func (v *Service) hasDB(app string) bool {
	if !valid.App(app) {
		return false
	}
	d, _ := v.AppConf(app, "database")
	return d == "postgres"
}

// Apps: the apps with a database, sorted
func (v *Service) Apps() []string {
	fs, _ := filepath.Glob(filepath.Join(v.cfg.Root, "apps", "*", "app.conf"))
	var r []string
	for _, f := range fs {
		a := filepath.Base(filepath.Dir(f))
		if v.hasDB(a) {
			r = append(r, a)
		}
	}
	sort.Strings(r)
	return r
}

// Mint makes a one-time code for admin to open app from the laptop's port (the root agent's
// db-studio-code, through the ctl socket). It works once, for CodeTTL, on that admin's socket
// only and with that port in Host.
func (v *Service) Mint(admin, app string, port int, host string) (string, error) {
	switch {
	case !nameRe.MatchString(admin) || !nameRe.MatchString(host):
		return "", errors.New("bad admin or host name")
	case port < 1024 || port > 65535:
		return "", errors.New("bad port")
	case !v.hasDB(app):
		return "", errNoDB
	}
	c := &svcCode{code: rnd(32), admin: admin, app: app, host: host, port: port, at: v.cfg.Now()}
	v.mu.Lock()
	v.expire()
	v.codes = append(v.codes, c)
	v.mu.Unlock()
	return c.code, nil
}

// expire drops old codes and tokens and stops their helpers (under mu)
func (v *Service) expire() {
	now := v.cfg.Now()
	cs := v.codes[:0]
	for _, c := range v.codes {
		if now.Sub(c.at) <= CodeTTL {
			cs = append(cs, c)
		}
	}
	v.codes = cs
	ss := v.sess[:0]
	for _, s := range v.sess {
		if now.Sub(s.last) <= TokenIdle {
			ss = append(ss, s)
		} else {
			v.stopSession(s.id)
		}
	}
	v.sess = ss
}

// Revoke ends every token and helper (app "": all; else that app's helpers only). The count of
// helpers stopped.
func (v *Service) Revoke(app string) int {
	v.mu.Lock()
	defer v.mu.Unlock()
	n := 0
	for _, h := range append([]*Helper(nil), v.helpers...) {
		if app == "" || h.App == app {
			v.dropHelper(h)
			n++
		}
	}
	if app == "" {
		v.sess, v.codes = nil, nil
	}
	return n
}

// Status: the tokens alive and the helpers running (app names)
func (v *Service) Status() (int, []string) {
	v.mu.Lock()
	defer v.mu.Unlock()
	v.expire()
	var a []string
	for _, h := range v.helpers {
		a = append(a, h.App)
	}
	sort.Strings(a)
	return len(v.sess), a
}

// ---- helpers ------------------------------------------------------------------------------------

var errFull = errors.New("the studio has as many database sessions open as it allows: close a studio tab, or wait a minute")

// dropHelper removes h and stops it (under mu)
func (v *Service) dropHelper(h *Helper) {
	for i, x := range v.helpers {
		if x == h {
			v.helpers = append(v.helpers[:i], v.helpers[i+1:]...)
			break
		}
	}
	if h.Stop != nil {
		go h.Stop()
	}
}

func (v *Service) stopSession(id string) {
	for _, h := range append([]*Helper(nil), v.helpers...) {
		if h.Sess == id {
			v.dropHelper(h)
		}
	}
}

// helper: the running helper of this session and app, started when there is none; at most
// HelpersPerApp per app and HelpersAll in all (the one unused longest gives way, never a busy
// one). release it after the request.
func (v *Service) helper(s *svcSession, app string) (*Helper, error) {
	v.mu.Lock()
	for _, h := range v.helpers {
		if h.Sess == s.id && h.App == app {
			h.busy++
			v.mu.Unlock()
			<-h.ready
			if h.err != nil {
				v.release(h)
				return nil, h.err
			}
			return h, nil
		}
	}
	per := 0
	for _, h := range v.helpers {
		if h.App == app {
			per++
		}
	}
	for per >= HelpersPerApp || len(v.helpers) >= HelpersAll {
		var lru *Helper
		for _, h := range v.helpers {
			if h.busy == 0 && (per < HelpersPerApp || h.App == app) && (lru == nil || h.last.Before(lru.last)) {
				lru = h
			}
		}
		if lru == nil {
			v.mu.Unlock()
			return nil, errFull
		}
		if lru.App == app {
			per--
		}
		v.dropHelper(lru)
	}
	h := &Helper{App: app, Host: s.host, Admin: s.admin, Sess: s.id, Port: s.port, ready: make(chan struct{}), busy: 1, last: v.cfg.Now()}
	v.helpers = append(v.helpers, h)
	v.mu.Unlock()
	h.err = v.cfg.Spawn(h)
	if h.err == nil {
		h.rp = v.proxy(h)
		go func() {
			<-h.Done
			v.mu.Lock()
			for i, x := range v.helpers {
				if x == h {
					v.helpers = append(v.helpers[:i], v.helpers[i+1:]...)
					break
				}
			}
			v.mu.Unlock()
		}()
	} else {
		v.mu.Lock()
		for i, x := range v.helpers {
			if x == h {
				v.helpers = append(v.helpers[:i], v.helpers[i+1:]...)
				break
			}
		}
		v.mu.Unlock()
	}
	close(h.ready)
	if h.err != nil {
		return nil, h.err
	}
	return h, nil
}

func (v *Service) release(h *Helper) {
	v.mu.Lock()
	h.busy--
	h.last = v.cfg.Now()
	v.mu.Unlock()
}

// the security headers are the front's (headers()); the helper's copies are dropped
var helperHdrs = []string{"Content-Security-Policy", "X-Content-Type-Options", "Referrer-Policy", "Cache-Control",
	"Cross-Origin-Opener-Policy", "Cross-Origin-Resource-Policy", "X-Frame-Options"}

// proxy: requests to h over its socket, as /api/<rest>, with h's own token. Host, Origin and
// Sec-Fetch-* go as they came (the helper checks them again against the same port).
func (v *Service) proxy(h *Helper) *httputil.ReverseProxy {
	tr := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) { return h.Dial(ctx) },
		MaxIdleConnsPerHost: 2, IdleConnTimeout: 30 * time.Second, ResponseHeaderTimeout: 2*DefaultLimit + 30*time.Second}
	return &httputil.ReverseProxy{
		Transport:     tr,
		FlushInterval: -1,
		Rewrite: func(p *httputil.ProxyRequest) {
			p.Out.URL.Scheme, p.Out.URL.Host = "http", "studio"
			p.Out.Host = p.In.Host
			p.Out.Header.Set("Authorization", "Bearer "+h.Token)
		},
		ModifyResponse: func(r *http.Response) error {
			for _, k := range helperHdrs {
				r.Header.Del(k)
			}
			return nil
		},
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			if errors.Is(err, context.Canceled) {
				return
			}
			fmt.Fprintf(v.cfg.Log, "tando-studio: the helper of %s: %v\n", h.App, err)
			apiErr(w, 503, "db_unavailable", "the studio of "+h.App+" stopped; try again")
		},
	}
}

// ---- the admins' sockets ------------------------------------------------------------------------

// Handler: the front of one admin's socket
func (v *Service) Handler(admin string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { v.serve(admin, w, r) })
}

func (v *Service) serve(admin string, w http.ResponseWriter, r *http.Request) {
	if !precheck(w, r, func(h string) bool { return loopPort(h) != 0 }, "<port>") {
		return
	}
	path := r.URL.Path
	if !strings.HasPrefix(path, "/api/") {
		serveStatic(w, r, v.static, v.probe)
		return
	}
	port := loopPort(r.Host)
	if path == "/api/session" {
		v.session(admin, port, w, r)
		return
	}
	tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	var s *svcSession
	v.mu.Lock()
	v.expire()
	for _, x := range v.sess {
		if ok && subtle.ConstantTimeCompare([]byte(tok), []byte(x.token)) == 1 && x.admin == admin && x.port == port {
			s = x
			x.last = v.cfg.Now()
		}
	}
	v.mu.Unlock()
	if s == nil {
		apiErr(w, 401, "auth", "this studio session has ended or the page has no key: run tando db studio again")
		return
	}
	switch path {
	case "/api/ping":
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte("{\"ok\":true}\n"))
		return
	case "/api/apps":
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		bw := bufio.NewWriter(w)
		j := (&jw{w: bw}).obj().k("app").s(s.app).k("host").s(s.host).k("apps").arr()
		for _, a := range v.Apps() {
			j.s(a)
		}
		j.aend().end()
		bw.Flush()
		return
	case "/api/end":
		v.mu.Lock()
		for i, x := range v.sess {
			if x == s {
				v.sess = append(v.sess[:i], v.sess[i+1:]...)
				break
			}
		}
		v.stopSession(s.id)
		v.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte("{\"ok\":true}\n"))
		return
	}
	app, rest := s.app, strings.TrimPrefix(path, "/api/")
	if x, ok := strings.CutPrefix(rest, "a/"); ok {
		app, rest, _ = strings.Cut(x, "/")
	}
	if rest == "" || rest == "session" || rest == "end" || strings.Contains(rest, "/") {
		apiErr(w, 404, "not_found", "no such endpoint")
		return
	}
	if !v.hasDB(app) {
		apiErr(w, 404, "no_app", "no app "+app+" with a database on this server")
		return
	}
	h, err := v.helper(s, app)
	if err != nil {
		code := 503
		if errors.Is(err, errFull) {
			code = 429
		}
		apiErr(w, code, "db_unavailable", err.Error())
		return
	}
	defer v.release(h)
	r.URL.Path, r.URL.RawPath = "/api/"+rest, ""
	h.rp.ServeHTTP(w, r)
}

// session: a code for a token, on the admin's socket the code was minted for and with its port
func (v *Service) session(admin string, port int, w http.ResponseWriter, r *http.Request) {
	var q struct{ Code string }
	if !decode(w, r, &q) {
		return
	}
	now := v.cfg.Now()
	v.mu.Lock()
	var c *svcCode
	for i, x := range v.codes {
		if subtle.ConstantTimeCompare([]byte(q.Code), []byte(x.code)) == 1 {
			c = x
			v.codes = append(v.codes[:i], v.codes[i+1:]...) // used: gone, whatever follows
			break
		}
	}
	if c == nil || now.Sub(c.at) > CodeTTL || c.admin != admin || c.port != port {
		v.mu.Unlock()
		apiErr(w, 401, "auth", "this link was already used or has expired: run tando db studio again")
		return
	}
	s := &svcSession{id: rnd(9), token: rnd(32), admin: c.admin, app: c.app, host: c.host, port: c.port, last: now}
	v.sess = append(v.sess, s)
	v.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	bw := bufio.NewWriter(w)
	(&jw{w: bw}).obj().k("token").s(s.token).k("app").s(s.app).end()
	bw.Flush()
}

// AdminSocket: the socket of admin (made on first use: Run/u/<admin>/s, root 0600 until the
// agent hands it to the admin), served by this front
func (v *Service) AdminSocket(admin string) (string, error) {
	if !nameRe.MatchString(admin) {
		return "", errors.New("bad admin name")
	}
	p := filepath.Join(v.cfg.Run, "u", admin, "s")
	v.mu.Lock()
	defer v.mu.Unlock()
	if _, ok := v.lns[admin]; ok {
		return p, nil
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o711); err != nil {
		return "", err
	}
	os.Chmod(filepath.Dir(filepath.Dir(p)), 0o711)
	os.Chmod(filepath.Dir(p), 0o711)
	os.Remove(p)
	ln, err := net.Listen("unix", p)
	if err != nil {
		return "", err
	}
	if err := os.Chmod(p, 0o600); err != nil {
		ln.Close()
		return "", err
	}
	v.lns[admin] = ln
	srv := &http.Server{Handler: v.Handler(admin), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second,
		WriteTimeout: 2*DefaultLimit + 30*time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16 << 10}
	v.srvs = append(v.srvs, srv)
	go srv.Serve(ln)
	return p, nil
}

// Ctl answers one line of the root agent on the ctl socket:
//
//	code <admin> <app> <port> <host>  -> code=<c> probe=<p> sock=<path>
//	revoke [app]                      -> revoked=<helpers stopped>
//	ls                                -> tokens=<n> helpers=<app,app|->
//
// errors: error=<message>
func (v *Service) Ctl(line string) string {
	f := strings.Fields(line)
	switch {
	case len(f) == 5 && f[0] == "code":
		port, ok := valid.Uint(f[3], 1024, 65535)
		if !ok {
			return "error=bad port"
		}
		code, err := v.Mint(f[1], f[2], int(port), f[4])
		if err != nil {
			return "error=" + err.Error()
		}
		p, err := v.AdminSocket(f[1])
		if err != nil {
			return "error=could not make the admin's socket: " + err.Error()
		}
		return "code=" + code + " probe=" + v.probe + " sock=" + p
	case len(f) <= 2 && len(f) >= 1 && f[0] == "revoke":
		app := ""
		if len(f) == 2 {
			if !valid.App(f[1]) {
				return "error=bad app name"
			}
			app = f[1]
		}
		return "revoked=" + strconv.Itoa(v.Revoke(app))
	case len(f) == 1 && f[0] == "ls":
		n, a := v.Status()
		h := strings.Join(a, ",")
		if h == "" {
			h = "-"
		}
		return "tokens=" + strconv.Itoa(n) + " helpers=" + h
	}
	return "error=bad request"
}

// ServeCtl answers the agent on ln (root 0600 in a root directory), one line per connection
func (v *Service) ServeCtl(ln net.Listener) error {
	for {
		c, err := ln.Accept()
		if err != nil {
			return err
		}
		go func() {
			defer c.Close()
			c.SetDeadline(time.Now().Add(10 * time.Second))
			l, err := bufio.NewReader(io.LimitReader(c, 512)).ReadString('\n')
			if err != nil {
				return
			}
			fmt.Fprintln(c, v.Ctl(strings.TrimSpace(l)))
		}()
	}
}

// Janitor: expired codes and tokens go every tick
func (v *Service) Janitor(tick time.Duration, stop <-chan struct{}) {
	t := time.NewTicker(tick)
	defer t.Stop()
	for {
		select {
		case <-stop:
			return
		case <-t.C:
			v.mu.Lock()
			v.expire()
			v.mu.Unlock()
		}
	}
}

// Shutdown: stop serving and stop every helper
func (v *Service) Shutdown() {
	v.mu.Lock()
	srvs := v.srvs
	v.mu.Unlock()
	for _, s := range srvs {
		ctx, cf := context.WithTimeout(context.Background(), 2*time.Second)
		s.Shutdown(ctx)
		cf()
	}
	v.Revoke("")
}

// CtlRequest: the agent's side (tando-studio ctl ...): one line to the service, its answer
func CtlRequest(path, line string) (string, error) {
	c, err := net.DialTimeout("unix", path, 5*time.Second)
	if err != nil {
		return "", errors.New("the studio service does not answer (sudo systemctl status tando-studio)")
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(15 * time.Second))
	fmt.Fprintln(c, line)
	l, err := bufio.NewReader(io.LimitReader(c, 4096)).ReadString('\n')
	if err != nil {
		return "", errors.New("the studio service did not answer")
	}
	return strings.TrimSpace(l), nil
}
