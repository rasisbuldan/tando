package dash

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"hash/fnv"
	"net/http"
	"runtime/debug"
	"strconv"
	"sync"
	"time"
)

// Logs (M3, review B3). A tail is one `tando logs <app> --json -n N ...` run. A follow is ONE
// `tando logs -f --json` child per (host, app, level, worker), shared by every tab that watches
// it over Server-Sent Events: a ring of the last lines for a late joiner, a bounded buffer per
// tab (a tab that cannot keep up is dropped, never the stream), heartbeats, the child stopped
// a while after its last viewer left, restarted with backoff when it dies while viewers remain
// (resuming with --since at the last line's second; the lines of that second already sent are
// skipped). Streams use the per-host ssh limit of every other run (Limiter) and at most
// StreamsPerHost of them run per host, so reads always keep a session.

// logs config defaults (Config fields, zero = default)
const (
	defLogRing        = 500
	defLogInitial     = 200  // -n of the first start
	defLogResume      = 1000 // -n of a restart (with --since)
	defClientBuf      = 256
	defHeartbeat      = 15 * time.Second
	defLinger         = 30 * time.Second
	defBackoff        = time.Second
	defBackoffMax     = 30 * time.Second
	defRestarts       = 5
	defSlotWait       = 5 * time.Second
	defStreamsPerHost = 2
	defStreams        = 16
	defSSEClients     = 32
	sseWriteTimeout   = 10 * time.Second
	sameSecondMax     = 4096 // hashes kept of the newest second's lines (dedup on restart)
)

// LogsConfig: the bounds of log streams (Config.Logs); zero values get the defaults above
type LogsConfig struct {
	Ring, Initial, Resume, ClientBuf, Restarts, StreamsPerHost, Streams, Clients int
	Heartbeat, Linger, Backoff, BackoffMax, SlotWait                             time.Duration
}

func (c *LogsConfig) defaults() {
	i := func(p *int, v int) {
		if *p == 0 {
			*p = v
		}
	}
	d := func(p *time.Duration, v time.Duration) {
		if *p == 0 {
			*p = v
		}
	}
	i(&c.Ring, defLogRing)
	i(&c.Initial, defLogInitial)
	i(&c.Resume, defLogResume)
	i(&c.ClientBuf, defClientBuf)
	i(&c.Restarts, defRestarts)
	i(&c.StreamsPerHost, defStreamsPerHost)
	i(&c.Streams, defStreams)
	i(&c.Clients, defSSEClients)
	d(&c.Heartbeat, defHeartbeat)
	d(&c.Linger, defLinger)
	d(&c.Backoff, defBackoff)
	d(&c.BackoffMax, defBackoffMax)
	d(&c.SlotWait, defSlotWait)
}

// ---- one-shot tail ----

// logQuery: host, app and the filters of a request, each checked; field names the bad one
func (s *Server) logQuery(w http.ResponseWriter, r *http.Request, tail bool) (host, app string, f logFilter, n int, ok bool) {
	q := r.URL.Query()
	host, app = q.Get("host"), q.Get("app")
	f = logFilter{Level: q.Get("level"), Worker: q.Get("worker")}
	if tail {
		f.Since, f.Grep, f.Release = q.Get("since"), q.Get("grep"), q.Get("release")
	} else {
		for _, k := range []string{"since", "grep", "release", "n"} {
			if q.Has(k) {
				apiErr(w, 400, "bad_request", k+": not with a follow (a follow takes level and worker)")
				return
			}
		}
	}
	n = 200
	bad := ""
	switch {
	case !ValidHost(host):
		bad = "host: letters, digits, . _ -"
	case !ValidApp(app):
		bad = "app: a-z, 0-9, -; 2-24 characters"
	case f.Level != "" && !ValidLevel(f.Level):
		bad = "level: err, warning, notice, info or debug"
	case f.Worker != "" && !ValidWorker(f.Worker):
		bad = "worker: a-z first, then a-z, 0-9, -"
	case f.Since != "" && !ValidSince(f.Since):
		bad = "since: 15m, 2h, 7d, 2026-11-13, 2026-11-13 14:30, 14:30 or @epoch (GMT)"
	case f.Grep != "" && !ValidGrep(f.Grep):
		bad = "grep: 1-256 characters, no control characters, not starting with -"
	case f.Release != "" && !ValidRelease(f.Release):
		bad = "release: a release id (YYYYMMDD-HHMMSS)"
	case q.Has("grep") && f.Grep == "", q.Has("since") && f.Since == "":
		bad = "an empty filter"
	}
	if bad == "" && tail && q.Has("n") {
		if !ValidCount(q.Get("n")) {
			bad = "n: 1 to " + strconv.Itoa(MaxLogLines)
		} else {
			n, _ = strconv.Atoi(q.Get("n"))
		}
	}
	if bad != "" {
		apiErr(w, 400, "bad_request", bad)
		return
	}
	if !s.knownHost(host) {
		apiErr(w, 404, "no_host", "no host named "+host+" (tando host ls)")
		return
	}
	return host, app, f, n, true
}

// GET /api/logs?host=&app=&n=&since=&level=&grep=&worker=&release=
func (s *Server) logsTail(w http.ResponseWriter, r *http.Request) {
	host, app, f, n, ok := s.logQuery(w, r, true)
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), s.cfg.ReadTimeout)
	defer cancel()
	res, err := s.run(ctx, Req{Argv: argvLogs(host, app, n, f), Host: host})
	if err != nil {
		if r.Context().Err() != nil {
			return
		}
		writeErr(w, cliErr(err))
		return
	}
	lines, notes := []json.RawMessage{}, []string{}
	for _, l := range bytes.Split(res.Stdout, []byte("\n")) {
		l = bytes.TrimRight(l, "\r")
		switch {
		case len(l) == 0:
		case l[0] == '{' && json.Valid(l):
			lines = append(lines, json.RawMessage(l))
		case len(notes) < 20: // "# release ... was never live" and the like
			notes = append(notes, firstLine(string(l)))
		}
	}
	writeJSON(w, 200, map[string]any{"host": host, "app": app, "ran_at": s.cfg.Now().UTC().Format(time.RFC3339),
		"lines": lines, "notes": notes})
}

// ---- follow: the hub ----

type streamKey struct{ host, app, level, worker string }

type event struct {
	id   int64 // line events only (the SSE id); 0 for the others
	name string
	data []byte
}

type client struct {
	ch   chan event
	gone chan struct{} // closed when the stream dropped this client (too slow)
}

type stream struct {
	key    streamKey
	h      *hub
	cancel context.CancelFunc
	done   chan struct{} // closed after the last event was handed out

	mu       sync.Mutex
	clients  map[*client]struct{}
	ring     []event // the last cfg.Ring line events, oldest first
	seq      int64
	ended    bool
	linger   *time.Timer
	lingerN  int
	pid      int
	sec      int64               // the newest second (unix) a line was seen in
	secLines map[uint64]struct{} // hashes of that second's lines
}

type hub struct {
	s       *Server
	cfg     LogsConfig
	mu      sync.Mutex
	streams map[streamKey]*stream
	clients int
	wg      sync.WaitGroup
	starts  int // children started (tests)
}

func newHub(s *Server, cfg LogsConfig) *hub {
	cfg.defaults()
	return &hub{s: s, cfg: cfg, streams: map[streamKey]*stream{}}
}

var (
	errStreamsHost = errors.New("this server already has its log streams running (tando-dash keeps one ssh session free for the pages); close a log tab and retry")
	errStreamsAll  = errors.New("too many log streams are open; close a log tab and retry")
	errClients     = errors.New("too many log tabs are open; close one and retry")
)

// join: the stream of key (started if none), the new client and the line events it missed
// (after lastID; all of the ring when lastID is 0)
func (h *hub) join(key streamKey, lastID int64) (*stream, *client, []event, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.clients >= h.cfg.Clients {
		return nil, nil, nil, errClients
	}
	st := h.streams[key]
	if st == nil {
		per := 0
		for k := range h.streams {
			if k.host == key.host {
				per++
			}
		}
		if per >= h.cfg.StreamsPerHost {
			return nil, nil, nil, errStreamsHost
		}
		if len(h.streams) >= h.cfg.Streams {
			return nil, nil, nil, errStreamsAll
		}
		ctx, cancel := context.WithCancel(h.s.base)
		st = &stream{key: key, h: h, cancel: cancel, done: make(chan struct{}), clients: map[*client]struct{}{},
			secLines: map[uint64]struct{}{}}
		h.streams[key] = st
		h.wg.Add(1)
		go st.run(ctx)
	}
	c := &client{ch: make(chan event, h.cfg.ClientBuf), gone: make(chan struct{})}
	h.clients++
	st.mu.Lock()
	st.clients[c] = struct{}{}
	if st.linger != nil {
		st.linger.Stop()
		st.linger = nil
	}
	var back []event
	for _, e := range st.ring {
		if e.id > lastID {
			back = append(back, e)
		}
	}
	st.mu.Unlock()
	return st, c, back, nil
}

// leave: the client went away; the last one starts the linger timer
func (st *stream) leave(c *client) {
	st.h.mu.Lock()
	st.h.clients--
	st.h.mu.Unlock()
	st.mu.Lock()
	defer st.mu.Unlock()
	if _, ok := st.clients[c]; ok {
		delete(st.clients, c)
	}
	st.lingerLocked()
}

func (st *stream) lingerLocked() {
	if len(st.clients) > 0 || st.ended || st.linger != nil {
		return
	}
	st.lingerN++
	n := st.lingerN
	st.linger = time.AfterFunc(st.h.cfg.Linger, func() {
		st.mu.Lock()
		stop := len(st.clients) == 0 && st.lingerN == n && st.linger != nil
		st.mu.Unlock()
		if stop {
			st.cancel()
		}
	})
}

// sendLocked: ev to every client; one whose buffer is full is dropped (it gets "dropped")
func (st *stream) sendLocked(ev event) {
	for c := range st.clients {
		select {
		case c.ch <- ev:
		default:
			delete(st.clients, c)
			close(c.gone)
		}
	}
	st.lingerLocked()
}

func (st *stream) send(name string, v any) {
	b, _ := json.Marshal(v)
	st.mu.Lock()
	st.sendLocked(event{name: name, data: b})
	st.mu.Unlock()
}

// onLine: one stdout line of the child. Not JSON: dropped. A line of the newest second already
// handed out (a restart resumes at that second) is skipped.
func (st *stream) onLine(b []byte) {
	if len(b) == 0 || b[0] != '{' || !json.Valid(b) {
		return
	}
	var meta struct {
		Usec int64 `json:"usec"`
	}
	_ = json.Unmarshal(b, &meta)
	hs := fnv.New64a()
	hs.Write(b)
	sum := hs.Sum64()
	st.mu.Lock()
	defer st.mu.Unlock()
	if meta.Usec > 0 {
		sec := meta.Usec / 1e6
		switch {
		case sec > st.sec:
			st.sec = sec
			clear(st.secLines)
			st.secLines[sum] = struct{}{}
		case sec == st.sec:
			if _, dup := st.secLines[sum]; dup {
				return
			}
			if len(st.secLines) < sameSecondMax {
				st.secLines[sum] = struct{}{}
			}
		}
	}
	st.seq++
	ev := event{id: st.seq, name: "line", data: append([]byte(nil), b...)}
	if len(st.ring) >= st.h.cfg.Ring {
		copy(st.ring, st.ring[1:])
		st.ring = st.ring[:len(st.ring)-1]
	}
	st.ring = append(st.ring, ev)
	st.sendLocked(ev)
}

// run: the child, restarted with backoff while it dies and viewers remain; then the end
func (st *stream) run(ctx context.Context) {
	h := st.h
	var final *event
	defer func() {
		if v := recover(); v != nil {
			h.s.logf("panic in a log stream: %v\n%s", v, firstLines(string(debug.Stack()), 12))
			b, _ := json.Marshal(apiError{Code: "internal", Msg: errPanic.Error()})
			final = &event{name: "error", data: b}
		}
		st.cancel()
		h.mu.Lock()
		if h.streams[st.key] == st {
			delete(h.streams, st.key)
		}
		h.mu.Unlock()
		st.mu.Lock()
		st.ended = true
		if st.linger != nil {
			st.linger.Stop()
		}
		if final != nil {
			st.sendLocked(*final)
		}
		close(st.done)
		st.mu.Unlock()
		h.wg.Done()
	}()
	sr, ok := h.s.cfg.Runner.(Streamer)
	if !ok {
		final = errEvent(&apiError{Code: "unsupported", Msg: "this tando-dash cannot follow logs"})
		return
	}
	fails, started := 0, false
	for {
		f := logFilter{Level: st.key.level, Worker: st.key.worker}
		n := h.cfg.Initial
		st.mu.Lock()
		if st.sec > 0 {
			f.Since, n = "@"+strconv.FormatInt(st.sec, 10), h.cfg.Resume
		}
		st.mu.Unlock()
		lines := 0
		t0 := time.Now()
		resumed := started
		_, err := sr.Stream(ctx, Req{Argv: argvLogsFollow(st.key.host, st.key.app, n, f), Host: st.key.host,
			SlotWait: h.cfg.SlotWait, OnStart: func(pid int) {
				h.mu.Lock()
				h.starts++
				h.mu.Unlock()
				st.mu.Lock()
				st.pid = pid
				st.mu.Unlock()
				if resumed {
					st.send("reconnected", map[string]any{"attempt": fails})
				}
			}}, func(b []byte) { lines++; st.onLine(b) })
		if ctx.Err() != nil {
			return // the last viewer left (linger), or tando-dash stops
		}
		if !started && errors.Is(err, ErrNoSlot) {
			final = errEvent(&apiError{Code: "busy", Msg: err.Error()})
			return
		}
		if errors.Is(err, ErrRefused) {
			final = errEvent(cliErr(err))
			return
		}
		started = true
		if lines > 0 || time.Since(t0) > h.cfg.BackoffMax {
			fails = 0
		}
		fails++
		msg := "the log stream ended"
		if err != nil {
			msg = err.Error()
		}
		if fails > h.cfg.Restarts {
			final = errEvent(&apiError{Code: "ended", Msg: "the log stream stopped after " + strconv.Itoa(fails-1) + " retries: " + msg})
			return
		}
		wait := h.cfg.Backoff << (fails - 1)
		if wait > h.cfg.BackoffMax || wait <= 0 {
			wait = h.cfg.BackoffMax
		}
		st.send("reconnecting", map[string]any{"attempt": fails, "retry_in_ms": wait.Milliseconds(), "message": msg})
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		}
	}
}

func errEvent(e *apiError) *event {
	b, _ := json.Marshal(e)
	return &event{name: "error", data: b}
}

// stats: streams and clients now (tests)
func (h *hub) stats() (streams, clients, starts int) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.streams), h.clients, h.starts
}

// ---- follow: the SSE handler ----

// GET /api/logs/stream?host=&app=&level=&worker=: Server-Sent Events. Events: hello (once:
// host, app, filters, buffered), line (data: one JSON line of tando logs --json; id: its number,
// so a reconnecting EventSource's Last-Event-ID gets only what it missed), reconnecting,
// reconnected, error (the last event: {code, message}), dropped (the last event: this tab
// was too slow). A comment every 15 s keeps the connection alive.
func (s *Server) logsStream(w http.ResponseWriter, r *http.Request) {
	host, app, f, _, ok := s.logQuery(w, r, false)
	if !ok {
		return
	}
	rc := http.NewResponseController(w)
	defer rc.SetWriteDeadline(time.Time{})
	hd := w.Header()
	hd.Set("Content-Type", "text/event-stream")
	hd.Set("Cache-Control", "no-store")
	hd.Set("X-Accel-Buffering", "no")
	w.WriteHeader(200)
	var buf bytes.Buffer
	flush := func() bool {
		_ = rc.SetWriteDeadline(time.Now().Add(sseWriteTimeout))
		_, err := w.Write(buf.Bytes())
		buf.Reset()
		return err == nil && rc.Flush() == nil
	}
	put := func(e event) {
		if e.id > 0 {
			fmt.Fprintf(&buf, "id: %d\n", e.id)
		}
		fmt.Fprintf(&buf, "event: %s\ndata: %s\n\n", e.name, e.data)
	}
	lastID, _ := strconv.ParseInt(r.Header.Get("Last-Event-ID"), 10, 64)
	st, c, back, err := s.hub.join(streamKey{host, app, f.Level, f.Worker}, lastID)
	buf.WriteString("retry: 5000\n\n")
	if err != nil {
		put(*errEvent(&apiError{Code: "busy", Msg: err.Error()}))
		flush()
		return
	}
	defer st.leave(c)
	hello, _ := json.Marshal(map[string]any{"host": host, "app": app, "level": f.Level, "worker": f.Worker, "buffered": len(back)})
	put(event{name: "hello", data: hello})
	for _, e := range back {
		put(e)
	}
	if !flush() {
		return
	}
	hb := time.NewTicker(s.hub.cfg.Heartbeat)
	defer hb.Stop()
	for {
		select {
		case e := <-c.ch:
			put(e)
			for more := true; more && buf.Len() < 64<<10; { // what is queued, in one write
				select {
				case e := <-c.ch:
					put(e)
				default:
					more = false
				}
			}
			if !flush() {
				return
			}
		case <-c.gone:
			put(event{name: "dropped", data: []byte(`{"message":"this tab fell behind the log stream; reopen the logs"}`)})
			flush()
			return
		case <-st.done:
			for more := true; more; {
				select {
				case e := <-c.ch:
					put(e)
				default:
					more = false
				}
			}
			flush()
			return
		case <-hb.C:
			s.lastUse.Store(s.cfg.Now().UnixNano()) // a tab watching logs is a use (--idle)
			buf.WriteString(": hb\n\n")
			if !flush() {
				return
			}
		case <-r.Context().Done():
			return
		case <-s.base.Done():
			return
		}
	}
}
