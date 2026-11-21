package dash

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

// Writes (spec "Idempotency, failure handling, robustness"). A write needs, on top of the
// session cookie:
//   - a confirm token from POST /api/confirm for exactly this action, host and app (single use,
//     60 s), issued when the confirmation dialog opens;
//   - an Idempotency-Key header (one per user action): the same key again returns the first
//     request's record and runs nothing; the same key with another body is 422;
//   - the app free: one write per (host, app); a second gets 409 with what runs and since when.
// The child runs in its own process group with its output in a file, so neither a client that
// goes away nor tando-dash stopping kills it (tando's CLI owns the operation).

// action: a write the page can ask for. M4 adds deploy, rollback, stop, start, restart, env set.
type action struct {
	argv func(host, app string) []string
}

// actions: noop is harmless (tando --version) and exercises the whole mechanism in tests
var actions = map[string]action{
	"noop": {argv: func(host, app string) []string { return []string{"--version"} }},
}

const maxConfirms = 128

type confirmTok struct {
	action, host, app string
	exp               time.Time
}

type confirms struct {
	mu  sync.Mutex
	now func() time.Time
	m   map[string]confirmTok
}

func newConfirms(now func() time.Time) *confirms {
	return &confirms{now: now, m: map[string]confirmTok{}}
}

func (c *confirms) issue(action, host, app string, ttl time.Duration) string {
	t := randHex(16)
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	for k, v := range c.m {
		if !v.exp.After(now) {
			delete(c.m, k)
		}
	}
	for len(c.m) >= maxConfirms {
		var ok string
		var ot time.Time
		for k, v := range c.m {
			if ok == "" || v.exp.Before(ot) {
				ok, ot = k, v.exp
			}
		}
		delete(c.m, ok)
	}
	c.m[t] = confirmTok{action, host, app, now.Add(ttl)}
	return t
}

// use: true once, for the action, host and app it was issued for, within 60 s
func (c *confirms) use(tok, action, host, app string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	for k, v := range c.m {
		if subtle.ConstantTimeCompare([]byte(k), []byte(tok)) == 1 {
			delete(c.m, k)
			return v.exp.After(c.now()) && v.action == action && v.host == host && v.app == app
		}
	}
	return false
}

type writeReq struct {
	Action  string          `json:"action"`
	Host    string          `json:"host"`
	App     string          `json:"app"`
	Confirm string          `json:"confirm,omitempty"`
	Params  json.RawMessage `json:"params,omitempty"`
}

func (q *writeReq) check() *apiError {
	if _, ok := actions[q.Action]; !ok {
		return &apiError{Status: 400, Code: "bad_request", Msg: "no such action"}
	}
	if !ValidHost(q.Host) {
		return &apiError{Status: 400, Code: "bad_request", Msg: "host: letters, digits, . _ -"}
	}
	if !ValidApp(q.App) {
		return &apiError{Status: 400, Code: "bad_request", Msg: "app: a-z, 0-9, -; 2-24 characters"}
	}
	return nil
}

// POST /api/confirm {action, host, app} -> {token, expires_in_s}
func (s *Server) confirm(w http.ResponseWriter, r *http.Request) {
	var q writeReq
	if _, ok := decode(w, r, &q); !ok {
		return
	}
	if e := q.check(); e != nil {
		writeErr(w, e)
		return
	}
	if !s.knownHost(q.Host) {
		apiErr(w, 404, "no_host", "no host named "+q.Host+" (tando host ls)")
		return
	}
	t := s.confirms.issue(q.Action, q.Host, q.App, s.cfg.ConfirmTTL)
	writeJSON(w, 200, map[string]any{"token": t, "expires_in_s": int(s.cfg.ConfirmTTL / time.Second)})
}

var keyRe = regexp.MustCompile(`^[A-Za-z0-9-]{8,128}$`)

// POST /api/action {action, host, app, confirm, params} with Idempotency-Key
func (s *Server) action(w http.ResponseWriter, r *http.Request) {
	key := r.Header.Get("Idempotency-Key")
	if !keyRe.MatchString(key) {
		apiErr(w, 400, "idempotency_key", "an Idempotency-Key header (8-128 letters, digits, -) is required")
		return
	}
	var q writeReq
	if _, ok := decode(w, r, &q); !ok {
		return
	}
	if e := q.check(); e != nil {
		writeErr(w, e)
		return
	}
	// the body that counts: everything but the confirm token (a retry of the same action may
	// come with a fresh token after the first was used)
	conf := q.Confirm
	q.Confirm = ""
	canon, _ := json.Marshal(q)
	hash := s.idem.hash(canon)

	rec, existing, err := s.idem.begin(r.Context(), key, hash, q)
	if err != nil {
		switch {
		case errors.Is(err, errKeyReused):
			apiErr(w, 422, "key_reused", "this Idempotency-Key was used for another request")
		case errors.Is(err, ErrBusy):
			apiErr(w, 503, "busy", "too many writes remembered; retry later")
		default:
			apiErr(w, 499, "cancelled", "cancelled")
		}
		return
	}
	if existing {
		writeJSON(w, rec.httpStatus(), rec.view(true, ""))
		return
	}
	// admission: the app free, then the confirm token; a refusal is not remembered
	lockKey := q.Host + "/" + q.App
	if cur, ok := s.writes.tryLock(lockKey, q.Action, key, s.cfg.Now()); !ok {
		e := &apiError{Status: 409, Code: "running", Msg: "a " + cur.Action + " of " + q.App + " is running, started " +
			cur.Since.UTC().Format("15:04:05") + " GMT", Extra: cur}
		s.idem.abort(key, e)
		writeErr(w, e)
		return
	}
	if !s.confirms.use(conf, q.Action, q.Host, q.App) {
		s.writes.unlock(lockKey)
		e := &apiError{Status: 403, Code: "confirm", Msg: "this confirmation has expired or was for something else; confirm again"}
		s.idem.abort(key, e)
		writeErr(w, e)
		return
	}
	if !s.knownHost(q.Host) {
		s.writes.unlock(lockKey)
		e := &apiError{Status: 404, Code: "no_host", Msg: "no host named " + q.Host + " (tando host ls)"}
		s.idem.abort(key, e)
		writeErr(w, e)
		return
	}
	argv := actions[q.Action].argv(q.Host, q.App)
	if _, err := Allowed(argv); err != nil {
		s.writes.unlock(lockKey)
		e := cliErr(err)
		s.idem.abort(key, e)
		writeErr(w, e)
		return
	}
	s.idem.start(rec)
	v := rec.view(false, "") // before the child can end and change the record
	s.wg.Add(1)
	go s.runWrite(rec, lockKey, argv, q.Host)
	writeJSON(w, 202, v)
}

// runWrite: the write's child, detached from the request and from shutdown
func (s *Server) runWrite(rec *idemRec, lockKey string, argv []string, host string) {
	defer s.wg.Done()
	defer s.writes.unlock(lockKey)
	defer func() {
		if v := recover(); v != nil {
			s.logf("panic in a write: %v", v)
			s.idem.finish(rec, "failed", -1, errPanic.Error())
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), s.cfg.WriteTimeout)
	defer cancel()
	var out *os.File
	if err := os.MkdirAll(s.idem.opsDir, 0o700); err == nil {
		out, _ = os.OpenFile(s.idem.logPath(rec.Key), os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	}
	if out != nil {
		defer out.Close()
	}
	res, err := s.cfg.Runner.Run(ctx, Req{Argv: argv, Host: host, Out: out, OnStart: func(pid int) { s.idem.setPid(rec, pid) }})
	status, msg := "done", ""
	if err != nil {
		status, msg = "failed", cliErr(err).Msg
		if s.idem.tail(rec.Key) == "" && res.Stderr != "" {
			msg = firstLine(res.Stderr)
		}
	}
	s.idem.finish(rec, status, res.Exit, msg)
}

// GET /api/action?key=: a write's record and the end of its output (a reloaded page reattaches)
func (s *Server) actionStatus(w http.ResponseWriter, r *http.Request) {
	key := r.URL.Query().Get("key")
	if !keyRe.MatchString(key) {
		apiErr(w, 400, "bad_request", "key")
		return
	}
	rec := s.idem.lookup(key)
	if rec == nil {
		apiErr(w, 404, "not_found", "no write with this key (records are kept 24 h)")
		return
	}
	writeJSON(w, 200, rec.view(false, s.idem.tail(key)))
}

// ---- one write per (host, app) ----

type running struct {
	Action string    `json:"action"`
	Since  time.Time `json:"since"`
	Key    string    `json:"key"`
}

type writeLocks struct {
	mu sync.Mutex
	m  map[string]running
}

func newWriteLocks() *writeLocks { return &writeLocks{m: map[string]running{}} }

func (l *writeLocks) tryLock(k, action, key string, now time.Time) (running, bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if cur, ok := l.m[k]; ok {
		return cur, false
	}
	l.m[k] = running{Action: action, Since: now, Key: key}
	return running{}, true
}

func (l *writeLocks) unlock(k string) {
	l.mu.Lock()
	delete(l.m, k)
	l.mu.Unlock()
}

func (l *writeLocks) count() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.m)
}

// ---- idempotency records: on disk (0600), bounded, 24 h ----

var errKeyReused = errors.New("key reused with another body")

type idemRec struct {
	Key     string    `json:"key"`
	Hash    string    `json:"hash"`
	Action  string    `json:"action"`
	Host    string    `json:"host"`
	App     string    `json:"app"`
	Status  string    `json:"status"` // running, done, failed, unknown
	Exit    int       `json:"exit"`
	Message string    `json:"message,omitempty"`
	Pid     int       `json:"pid,omitempty"`
	Started time.Time `json:"started"`
	Ended   time.Time `json:"ended,omitempty"`

	admitted chan struct{} // closed when admission is decided
	reject   *apiError     // admission refused (the record is then forgotten)
}

func (r *idemRec) httpStatus() int {
	if r.reject != nil {
		return r.reject.Status
	}
	if r.Status == "running" {
		return 202
	}
	return 200
}

// view: what the API answers about a write
func (r *idemRec) view(replay bool, output string) map[string]any {
	if r.reject != nil {
		return map[string]any{"error": r.reject, "replay": replay}
	}
	v := map[string]any{"key": r.Key, "action": r.Action, "host": r.Host, "app": r.App, "status": r.Status,
		"started_at": r.Started.UTC().Format(time.RFC3339), "replay": replay}
	if !r.Ended.IsZero() {
		v["ended_at"] = r.Ended.UTC().Format(time.RFC3339)
		v["exit"] = r.Exit
	}
	if r.Message != "" {
		v["message"] = r.Message
	}
	if output != "" {
		v["output"] = output
	}
	return v
}

type idemStore struct {
	mu     sync.Mutex
	file   string
	opsDir string
	max    int
	ttl    time.Duration
	now    func() time.Time
	secret []byte
	m      map[string]*idemRec
}

type idemFile struct {
	Secret  string     `json:"secret"`
	Records []*idemRec `json:"records"`
}

func openIdem(file, opsDir string, max int, ttl time.Duration, now func() time.Time) (*idemStore, error) {
	st := &idemStore{file: file, opsDir: opsDir, max: max, ttl: ttl, now: now, m: map[string]*idemRec{}}
	var f idemFile
	if b, err := os.ReadFile(file); err == nil {
		if json.Unmarshal(b, &f) != nil {
			f = idemFile{} // a damaged file is started over: refusing to start would be worse
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if s, err := hex.DecodeString(f.Secret); err == nil && len(s) == 32 {
		st.secret = s
	} else {
		st.secret, _ = hex.DecodeString(randHex(32))
	}
	for _, r := range f.Records {
		if r == nil || !keyRe.MatchString(r.Key) {
			continue
		}
		if r.Status == "running" { // tando-dash stopped while it ran: tando has the outcome
			r.Status, r.Message = "unknown", "tando-dash restarted while this ran; read the outcome from tando (status, history)"
		}
		r.admitted = make(chan struct{})
		close(r.admitted)
		st.m[r.Key] = r
	}
	st.mu.Lock()
	st.pruneLocked()
	err := st.saveLocked()
	st.mu.Unlock()
	return st, err
}

// hash: HMAC of the canonical body (M4's env set puts a value in it: no plain hash of a secret)
func (st *idemStore) hash(b []byte) string {
	m := hmac.New(sha256.New, st.secret)
	m.Write(b)
	return hex.EncodeToString(m.Sum(nil))
}

func (st *idemStore) logPath(key string) string {
	return filepath.Join(st.opsDir, hashHex(key)[:32]+".log")
}

// begin: the record of key: an existing one (after its admission is decided), or a new pending one
func (st *idemStore) begin(ctx context.Context, key, hash string, q writeReq) (*idemRec, bool, error) {
	st.mu.Lock()
	if r := st.m[key]; r != nil {
		st.mu.Unlock()
		if subtle.ConstantTimeCompare([]byte(r.Hash), []byte(hash)) != 1 {
			return nil, false, errKeyReused
		}
		select {
		case <-r.admitted:
		case <-ctx.Done():
			return nil, false, ctx.Err()
		}
		st.mu.Lock()
		defer st.mu.Unlock()
		cp := *r
		return &cp, true, nil
	}
	st.pruneLocked()
	if len(st.m) >= st.max {
		st.mu.Unlock()
		return nil, false, ErrBusy
	}
	r := &idemRec{Key: key, Hash: hash, Action: q.Action, Host: q.Host, App: q.App, Status: "pending",
		Started: st.now(), admitted: make(chan struct{})}
	st.m[key] = r
	st.mu.Unlock()
	return r, false, nil
}

// abort: admission refused: the waiters get the refusal, the key can be used again
func (st *idemStore) abort(key string, e *apiError) {
	st.mu.Lock()
	defer st.mu.Unlock()
	if r := st.m[key]; r != nil && r.Status == "pending" {
		r.reject = e
		delete(st.m, key)
		close(r.admitted)
	}
}

func (st *idemStore) start(r *idemRec) {
	st.mu.Lock()
	defer st.mu.Unlock()
	r.Status = "running"
	r.Started = st.now()
	close(r.admitted)
	st.saveLocked()
}

func (st *idemStore) setPid(r *idemRec, pid int) {
	st.mu.Lock()
	defer st.mu.Unlock()
	r.Pid = pid
	st.saveLocked()
}

func (st *idemStore) finish(r *idemRec, status string, exit int, msg string) {
	st.mu.Lock()
	defer st.mu.Unlock()
	r.Status, r.Exit, r.Message, r.Ended = status, exit, msg, st.now()
	st.saveLocked()
}

func (st *idemStore) lookup(key string) *idemRec {
	st.mu.Lock()
	defer st.mu.Unlock()
	r := st.m[key]
	if r == nil || r.Status == "pending" {
		return nil
	}
	cp := *r
	return &cp
}

// tail: the last 8 KB of a write's output, whole lines
func (st *idemStore) tail(key string) string {
	f, err := os.Open(st.logPath(key))
	if err != nil {
		return ""
	}
	defer f.Close()
	const n = 8 << 10
	fi, err := f.Stat()
	if err != nil {
		return ""
	}
	off := fi.Size() - n
	if off < 0 {
		off = 0
	}
	b, _ := io.ReadAll(io.NewSectionReader(f, off, n))
	s := string(b)
	if off > 0 {
		if _, after, ok := strings.Cut(s, "\n"); ok {
			s = after
		}
	}
	return s
}

// pruneLocked: drop records past 24 h, then the oldest ended ones over the bound
func (st *idemStore) pruneLocked() {
	now := st.now()
	var ended []*idemRec
	for k, r := range st.m {
		if r.Status == "pending" || r.Status == "running" {
			continue
		}
		if now.Sub(r.Started) > st.ttl {
			delete(st.m, k)
			os.Remove(st.logPath(k))
			continue
		}
		ended = append(ended, r)
	}
	if len(st.m) < st.max {
		return
	}
	sort.Slice(ended, func(i, j int) bool { return ended[i].Started.Before(ended[j].Started) })
	for _, r := range ended {
		if len(st.m) < st.max {
			break
		}
		delete(st.m, r.Key)
		os.Remove(st.logPath(r.Key))
	}
}

func (st *idemStore) saveLocked() error {
	f := idemFile{Secret: hex.EncodeToString(st.secret)}
	for _, r := range st.m {
		if r.Status != "pending" {
			f.Records = append(f.Records, r)
		}
	}
	sort.Slice(f.Records, func(i, j int) bool { return f.Records[i].Started.Before(f.Records[j].Started) })
	b, err := json.Marshal(f)
	if err != nil {
		return err
	}
	return writeFileAtomic(st.file, b, 0o600)
}

func (st *idemStore) count() int {
	st.mu.Lock()
	defer st.mu.Unlock()
	return len(st.m)
}
