package dash

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime/debug"
	"sync"
	"time"
)

// Reads (review B1, S1): one `tando snapshot --json` per (host, app, range) per 10 s whatever
// the number of tabs (cache + single flight), and a poll hint so the page asks every 15 s while
// visible and every 60 s off-screen. doctor and host status run on demand, at most once a
// minute per host (hostcare does a full collection each time).

var errPanic = errors.New("tando-dash failed on this request; it keeps running")

// safeFetch: a panic in a run is that run's error, not the end of the process
func safeFetch(ctx context.Context, logw io.Writer, fetch func(context.Context) (json.RawMessage, error)) (d json.RawMessage, err error) {
	defer func() {
		if v := recover(); v != nil {
			fmt.Fprintf(logw, "tando-dash: panic in a read: %v\n%s\n", v, firstLines(string(debug.Stack()), 12))
			d, err = nil, errPanic
		}
	}()
	return fetch(ctx)
}

var errBadOutput = errors.New("tando printed something that is not JSON (update tando, or run the command in a terminal to see why)")

type entry struct {
	data json.RawMessage
	err  error
	at   time.Time
}

type flight struct {
	done   chan struct{}
	res    entry
	refs   int
	cancel context.CancelFunc
}

// cache: bounded map with single flight. A run is shared by every request that wants the same
// key; it is cancelled (its child killed) when the last of them goes away.
type cache struct {
	mu      sync.Mutex
	m       map[string]*entry
	fl      map[string]*flight
	max     int
	keepErr bool // hostcare: a failure counts as a run for the once-a-minute rule
	runs    int  // runs started (tests)
	logw    io.Writer
}

func newCache(max int, keepErr bool) *cache {
	return &cache{m: map[string]*entry{}, fl: map[string]*flight{}, max: max, keepErr: keepErr, logw: os.Stderr}
}

// get: a fresh entry (cached=true), or the result of a run shared with other waiters
func (c *cache) get(ctx, base context.Context, key string, ttl, timeout time.Duration, now func() time.Time,
	fetch func(context.Context) (json.RawMessage, error)) (e entry, cached bool, err error) {
	c.mu.Lock()
	if e := c.m[key]; e != nil && now().Sub(e.at) < ttl {
		c.mu.Unlock()
		return *e, true, e.err
	}
	f := c.fl[key]
	if f == nil {
		rctx, cancel := context.WithTimeout(base, timeout)
		f = &flight{done: make(chan struct{}), cancel: cancel}
		c.fl[key] = f
		c.runs++
		go func() {
			defer cancel()
			d, err := safeFetch(rctx, c.logw, fetch)
			res := entry{data: d, err: err, at: now()}
			c.mu.Lock()
			if err == nil || c.keepErr && !errors.Is(err, context.Canceled) {
				c.m[key] = &res
				c.evictLocked()
			}
			delete(c.fl, key)
			f.res = res
			close(f.done)
			c.mu.Unlock()
		}()
	}
	f.refs++
	c.mu.Unlock()
	select {
	case <-f.done:
		return f.res, false, f.res.err
	case <-ctx.Done():
		c.mu.Lock()
		f.refs--
		if f.refs == 0 {
			f.cancel()
		}
		c.mu.Unlock()
		return entry{}, false, ctx.Err()
	}
}

func (c *cache) evictLocked() {
	for len(c.m) > c.max {
		var ok string
		var ot time.Time
		for k, e := range c.m {
			if ok == "" || e.at.Before(ot) {
				ok, ot = k, e.at
			}
		}
		delete(c.m, ok)
	}
}

func (c *cache) stats() (entries, runs int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.m), c.runs
}

// jsonRun: run argv and insist on JSON
func (s *Server) jsonRun(host string, argv []string) func(context.Context) (json.RawMessage, error) {
	return s.jsonRunIn("", host, argv)
}

// jsonRunIn: the same, run in dir
func (s *Server) jsonRunIn(dir, host string, argv []string) func(context.Context) (json.RawMessage, error) {
	return func(ctx context.Context) (json.RawMessage, error) {
		res, err := s.run(ctx, Req{Argv: argv, Host: host, Dir: dir})
		if err != nil {
			return nil, err
		}
		if !json.Valid(res.Stdout) {
			return nil, errBadOutput
		}
		return json.RawMessage(res.Stdout), nil
	}
}

func (s *Server) pollHint(r *http.Request) int {
	if r.URL.Query().Get("visible") == "0" {
		return s.cfg.PollHidden
	}
	return s.cfg.PollVisible
}

type snapOut struct {
	Host      string          `json:"host"`
	App       string          `json:"app,omitempty"`
	Range     string          `json:"range,omitempty"`
	FetchedAt string          `json:"fetched_at"`
	AgeS      int             `json:"age_s"`
	Cached    bool            `json:"cached"`
	NextPollS int             `json:"next_poll_s"`
	Data      json.RawMessage `json:"data"`
}

// fetchSnap: the cached snapshot of (host, app, range)
func (s *Server) fetchSnap(ctx context.Context, host, app, rng string) (entry, bool, error) {
	key := host + "\x00" + app + "\x00" + rng
	return s.snaps.get(ctx, s.base, key, s.cfg.CacheTTL, s.cfg.ReadTimeout, s.cfg.Now, s.jsonRun(host, argvSnapshot(host, app, rng)))
}

// GET /api/snapshot?host=&app=&range=&visible=
func (s *Server) snapshot(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	host, app, rng := q.Get("host"), q.Get("app"), q.Get("range")
	switch {
	case !ValidHost(host):
		apiErr(w, 400, "bad_request", "host: letters, digits, . _ -")
		return
	case app != "" && !ValidApp(app):
		apiErr(w, 400, "bad_request", "app: a-z, 0-9, -; 2-24 characters")
		return
	case rng != "" && !ValidRange(rng):
		apiErr(w, 400, "bad_request", "range: 1h, 24h or 7d")
		return
	case !s.knownHost(host):
		apiErr(w, 404, "no_host", "no host named "+host+" (tando host ls)")
		return
	}
	e, cached, err := s.fetchSnap(r.Context(), host, app, rng)
	poll := s.pollHint(r)
	if err != nil {
		if r.Context().Err() != nil {
			return
		}
		ae := cliErr(err)
		writeJSON(w, ae.Status, map[string]any{"error": ae, "next_poll_s": poll})
		return
	}
	writeJSON(w, 200, snapOut{Host: host, App: app, Range: rng, FetchedAt: e.at.UTC().Format(time.RFC3339),
		AgeS: int(s.cfg.Now().Sub(e.at) / time.Second), Cached: cached, NextPollS: poll, Data: e.data})
}

type hostOut struct {
	Host      string          `json:"host"`
	OK        bool            `json:"ok"`
	FetchedAt string          `json:"fetched_at,omitempty"`
	Cached    bool            `json:"cached,omitempty"`
	Data      json.RawMessage `json:"data,omitempty"`
	Error     *apiError       `json:"error,omitempty"`
}

// GET /api/overview?visible=: every host's snapshot in parallel, each with its own timeout;
// a host that fails is one error in the list, the others answer. Writes the menu bar's cache.
func (s *Server) overview(w http.ResponseWriter, r *http.Request) {
	hosts := s.Hosts()
	out := make([]hostOut, len(hosts))
	var wg sync.WaitGroup
	for i, h := range hosts {
		wg.Add(1)
		go func() {
			defer wg.Done()
			e, cached, err := s.fetchSnap(r.Context(), h, "", "")
			if err != nil {
				out[i] = hostOut{Host: h, Error: cliErr(err)}
				return
			}
			out[i] = hostOut{Host: h, OK: true, FetchedAt: e.at.UTC().Format(time.RFC3339), Cached: cached, Data: e.data}
		}()
	}
	wg.Wait()
	if r.Context().Err() != nil {
		return
	}
	s.writeLsAll(out)
	writeJSON(w, 200, map[string]any{"hosts": out, "studios": s.studios.list(), "next_poll_s": s.pollHint(r)})
}

// GET /api/doctor?host= and /api/hoststatus?host=: at most one run a minute per host
func (s *Server) hostcare(w http.ResponseWriter, r *http.Request, kind string) {
	host := r.URL.Query().Get("host")
	if !ValidHost(host) {
		apiErr(w, 400, "bad_request", "host: letters, digits, . _ -")
		return
	}
	if !s.knownHost(host) {
		apiErr(w, 404, "no_host", "no host named "+host+" (tando host ls)")
		return
	}
	argv := argvDoctor(host)
	if kind == "hoststatus" {
		argv = argvHostStatus(host)
	}
	e, cached, err := s.care.get(r.Context(), s.base, kind+"\x00"+host, s.cfg.HostCareTTL, s.cfg.ReadTimeout, s.cfg.Now, s.jsonRun(host, argv))
	if err != nil && r.Context().Err() != nil {
		return
	}
	again := int((s.cfg.HostCareTTL - s.cfg.Now().Sub(e.at)) / time.Second)
	if again < 0 {
		again = 0
	}
	body := map[string]any{"host": host, "ran_at": e.at.UTC().Format(time.RFC3339), "cached": cached, "next_run_s": again}
	if err != nil {
		ae := cliErr(err)
		body["error"] = ae
		writeJSON(w, ae.Status, body)
		return
	}
	body["data"] = e.data
	writeJSON(w, 200, body)
}

// writeLsAll: ~/.config/tando/cache/ls-all.json in the shape of `tando ls --all --json`, which
// the menu bar reads instead of polling while tando-dash runs (review S2). Snapshot fields are
// read tolerantly: apps and alerts at the top or under "status"; unknown fields are ignored.
func (s *Server) writeLsAll(hosts []hostOut) {
	type app struct {
		App   string  `json:"app"`
		State *string `json:"state"`
		Link  *string `json:"link"`
	}
	type row struct {
		Host   string            `json:"host"`
		Apps   []app             `json:"apps"`
		Alerts []json.RawMessage `json:"alerts"`
		Error  *string           `json:"error,omitempty"`
	}
	rows := make([]row, 0, len(hosts))
	for _, h := range hosts {
		rw := row{Host: h.Host, Apps: []app{}, Alerts: []json.RawMessage{}}
		if !h.OK {
			msg := h.Error.Msg
			rw.Error = &msg
			rows = append(rows, rw)
			continue
		}
		var snap struct {
			Apps   []map[string]any  `json:"apps"`
			Alerts []json.RawMessage `json:"alerts"`
			Status *struct {
				Apps   []map[string]any  `json:"apps"`
				Alerts []json.RawMessage `json:"alerts"`
			} `json:"status"`
		}
		_ = json.Unmarshal(h.Data, &snap)
		apps, alerts := snap.Apps, snap.Alerts
		if snap.Status != nil {
			if apps == nil {
				apps = snap.Status.Apps
			}
			if alerts == nil {
				alerts = snap.Status.Alerts
			}
		}
		for _, a := range apps {
			name := str(a["app"])
			if name == nil {
				name = str(a["name"])
			}
			if name == nil {
				continue
			}
			rw.Apps = append(rw.Apps, app{App: *name, State: str(a["state"]), Link: str(a["link"])})
		}
		if alerts != nil {
			rw.Alerts = alerts
		}
		rows = append(rows, rw)
	}
	b, err := json.Marshal(map[string]any{"hosts": rows, "generated_at": s.cfg.Now().UTC().Format(time.RFC3339), "source": "tando-dash"})
	if err != nil {
		return
	}
	if err := writeFileAtomic(filepath.Join(s.cfg.ConfigDir, "cache", "ls-all.json"), append(b, '\n'), 0o600); err != nil {
		s.logf("could not write the menu bar cache: %v", err)
	}
}

func str(v any) *string {
	if s, ok := v.(string); ok {
		return &s
	}
	return nil
}
