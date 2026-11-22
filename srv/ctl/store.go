package ctl

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"tando/srv/internal/atomicfile"
	"tando/srv/internal/lock"
)

// The request store makes every mutating request idempotent by its request_id, and runs the
// requests of one app one at a time, in the order they arrived.
//
// Dir (/var/lib/tando/ctl, root 700):
//
//	store.lock            held for a moment while a record is looked up or written
//	seq                   the last sequence number given to a request
//	key                   32 random bytes: the key of the digests (HMAC), never leaves the node
//	req/<ns>/<id>.json    the record: the request's digest, app, seq, state (pending|done) and,
//	                      when done, the response; written (fsynced) before the request runs
//	req/<ns>/<id>.lock    held by the process running the request, for as long as it runs: a
//	                      retry waits on it; a pending record whose lock nobody holds was cut off
//	queue/<app>/<seq>-<ns>+<id>  a request of that app waiting or running; removed when it is done
//
// <ns> is the principal's namespace (write, read, app-<app>): ids, quotas and eviction are per
// principal, so one certificate can neither claim nor push out another's request ids. A
// namespace holds at most Cap records; past it the oldest done ones older than Recent go, and
// when none may go the request is refused (busy), never a record of another principal.
// Requests refused before they did anything (bad_request, not_found) are not kept.
//
// A retry with the same id and the same request gets the first response, waiting for it while
// the first is still running; the same id with a different request is refused (conflict). Done
// records are kept for Retention (and at most MaxRecords), then removed.
//
// New verbs (artifact deploy, hold, apply, drain) plug in as a verb whose run function does the
// work: the store neither knows nor cares what a request does.

const (
	Retention  = 7 * 24 * time.Hour
	MaxRecords = 20000          // per namespace (Store.Cap)
	Recent     = 24 * time.Hour // a done record younger than this is never pushed out
	pruneEvery = 10 * time.Minute
)

// Store is the request store in Dir.
type Store struct {
	Dir string
	NS  string // the principal's namespace: write, read, app-<app>
	Cap int    // records per namespace (0: MaxRecords)
	Now func() time.Time
	// Poll is how often a request waiting for its turn looks again (0: 100 ms).
	Poll time.Duration
}

type record struct {
	ID       string    `json:"id"`
	Digest   string    `json:"digest"`
	Verb     string    `json:"verb"`
	App      string    `json:"app,omitempty"`
	Seq      int64     `json:"seq"`
	State    string    `json:"state"` // pending | done
	Created  int64     `json:"created"`
	Finished int64     `json:"finished,omitempty"`
	Response *Response `json:"response,omitempty"`
}

// Digest identifies a request's content: principal namespace, verb, app and arguments
// (compacted), as an HMAC with the node's key. The arguments can hold secrets (env values): only
// this keyed hash is kept, so a copy of the store does not allow guessing them offline.
func Digest(key []byte, ns string, r Request) string {
	h := hmac.New(sha256.New, key)
	fmt.Fprintf(h, "%s\x00%s\x00%s\x00", ns, r.Verb, r.App)
	var args []byte
	if len(r.Args) > 0 {
		var v any
		if json.Unmarshal(r.Args, &v) == nil {
			args, _ = json.Marshal(v) // (map keys sorted: the same arguments in another order match)
		}
	}
	h.Write(args)
	return hex.EncodeToString(h.Sum(nil))
}

func (s *Store) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

func (s *Store) path(p ...string) string { return filepath.Join(append([]string{s.Dir}, p...)...) }

func (s *Store) cap() int {
	if s.Cap > 0 {
		return s.Cap
	}
	return MaxRecords
}

func (s *Store) rec(id string) string { return s.path("req", s.NS, id+".json") }
func (s *Store) lck(id string) string { return s.path("req", s.NS, id+".lock") }
func (s *Store) qname(seq int64, id string) string {
	return fmt.Sprintf("%016d-%s+%s", seq, s.NS, id)
}

var nsRe = regexp.MustCompile(`^(write|read|app-[a-z][a-z0-9-]{1,30})$`)

// key is the node's digest key (made on first use).
func (s *Store) key() ([]byte, error) {
	p := s.path("key")
	if b, err := os.ReadFile(p); err == nil && len(b) == 32 {
		return b, nil
	}
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return nil, err
	}
	if err := atomicfile.Write(p, b, atomicfile.Mode(0o600)); err != nil {
		return nil, err
	}
	return b, nil
}

func (s *Store) init() error {
	if !nsRe.MatchString(s.NS) {
		return errors.New("bad namespace")
	}
	for _, d := range []string{s.Dir, s.path("req"), s.path("req", s.NS), s.path("queue")} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			return err
		}
		if err := os.Chmod(d, 0o700); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) load(id string) (record, bool) {
	b, err := os.ReadFile(s.rec(id))
	if err != nil {
		return record{}, false
	}
	var r record
	if json.Unmarshal(b, &r) != nil || r.ID != id {
		return record{}, false
	}
	return r, true
}

func (s *Store) save(r record) error {
	b, err := json.Marshal(r)
	if err != nil {
		return err
	}
	return atomicfile.Write(s.rec(r.ID), append(b, '\n'), atomicfile.Mode(0o600))
}

func (s *Store) nextSeq() (int64, error) {
	b, _ := os.ReadFile(s.path("seq"))
	n, _ := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
	n++
	return n, atomicfile.Write(s.path("seq"), []byte(strconv.FormatInt(n, 10)+"\n"), atomicfile.Mode(0o600))
}

// errBusyStore: the store lock was not free within its timeout.
var errBusyStore = errors.New("the request store is busy")

// Do runs req once: run is called only for an id the store has not seen; a retry gets the stored
// response (Replayed), waiting up to wait for one that is still running.
func (s *Store) Do(req Request, wait time.Duration, run func() Response) Response {
	if err := s.init(); err != nil {
		return fail(req, "internal", "the request store cannot be written: "+err.Error())
	}
	sl, err := lock.Acquire(s.path("store.lock"), 30*time.Second)
	if err != nil {
		return fail(req, "busy", errBusyStore.Error()+": try again")
	}
	key, err := s.key()
	if err != nil {
		sl.Release()
		return fail(req, "internal", "the request store cannot be written: "+err.Error())
	}
	dg := Digest(key, s.NS, req)
	rec, seen := s.load(req.RequestID)
	if seen {
		sl.Release()
		if rec.Digest != dg {
			return fail(req, "conflict", "request_id "+req.RequestID+" was used for a different request ("+rec.Verb+"): use a new id")
		}
		return s.await(req, rec, wait, run)
	}
	if !s.room() {
		sl.Release()
		return fail(req, "busy", fmt.Sprintf("this principal has %d request records from the last %s: try again later", s.cap(), Recent))
	}
	held, err := lock.Acquire(s.lck(req.RequestID), 0)
	if err != nil {
		sl.Release()
		return fail(req, "busy", "request "+req.RequestID+" is being started by another session: try again")
	}
	defer held.Release()
	seq, err := s.nextSeq()
	if err == nil {
		rec = record{ID: req.RequestID, Digest: dg, Verb: req.Verb, App: req.App, Seq: seq, State: "pending", Created: s.now().Unix()}
		err = s.save(rec)
	}
	q := ""
	if err == nil && req.App != "" {
		qd := s.path("queue", req.App)
		q = filepath.Join(qd, s.qname(seq, req.RequestID))
		if err = os.MkdirAll(qd, 0o700); err == nil {
			err = os.WriteFile(q, nil, 0o600)
		}
	}
	sl.Release()
	if err != nil {
		os.Remove(s.rec(req.RequestID))
		return fail(req, "internal", "the request store cannot be written: "+err.Error())
	}
	s.waitTurn(req.App, seq)
	resp := run()
	resp.RequestID = req.RequestID
	rec.State, rec.Finished, rec.Response = "done", s.now().Unix(), &resp
	if sl, err = lock.Acquire(s.path("store.lock"), 5*time.Minute); err == nil {
		if resp.Error != nil && (resp.Error.Code == "bad_request" || resp.Error.Code == "not_found") {
			os.Remove(s.rec(rec.ID)) // refused before it did anything: nothing to keep
		} else if err := s.save(rec); err != nil {
			resp.Warning = "the result could not be stored (" + err.Error() + "): a retry with this id reports it interrupted"
		}
		if q != "" {
			os.Remove(q)
		}
		s.prune()
		sl.Release()
	}
	return resp
}

// await waits for a pending record's runner and returns the stored response.
func (s *Store) await(req Request, rec record, wait time.Duration, run func() Response) Response {
	if rec.State != "done" {
		l, err := lock.Acquire(s.lck(req.RequestID), wait)
		if err != nil {
			return fail(req, "pending", "request "+req.RequestID+" is still running: ask again with the same request_id")
		}
		l.Release()
		r, ok := s.load(req.RequestID)
		if !ok { // the first was refused before it did anything (not kept): this one is checked anew
			return s.Do(req, wait, run)
		}
		rec = r
	}
	if rec.State != "done" || rec.Response == nil {
		// nobody runs it and it has no result: the process running it was cut off (a crash, a
		// reboot). That is its result from now on: a retry must not do the work a second time.
		r := fail(req, "interrupted", "this request was cut off while it ran (the node restarted, or tando-gate was killed); "+
			"tando finishes or undoes the step itself: read app.status, then send a new request with a new request_id")
		r.RequestID = req.RequestID
		if sl, err := lock.Acquire(s.path("store.lock"), 30*time.Second); err == nil {
			cur, ok := s.load(req.RequestID)
			if ok && cur.State == "done" && cur.Response != nil {
				r = *cur.Response
			} else {
				rec.State, rec.Finished, rec.Response = "done", s.now().Unix(), &r
				s.save(rec)
				s.unqueue(rec)
			}
			sl.Release()
		}
		return replay(r)
	}
	return replay(*rec.Response)
}

func replay(r Response) Response { r.Replayed = true; return r }

func (s *Store) unqueue(r record) {
	if r.App != "" {
		os.Remove(s.path("queue", r.App, s.qname(r.Seq, r.ID)))
	}
}

// waitTurn waits until no earlier request of the app is waiting or running. A queue entry whose
// runner is gone (its lock free) does not hold the queue up.
func (s *Store) waitTurn(app string, seq int64) {
	if app == "" {
		return
	}
	poll := s.Poll
	if poll == 0 {
		poll = 100 * time.Millisecond
	}
	for {
		ents, _ := os.ReadDir(s.path("queue", app))
		blocked := false
		for _, e := range ents {
			n, rest, ok := strings.Cut(e.Name(), "-")
			ns, id, ok2 := strings.Cut(rest, "+")
			q, err := strconv.ParseInt(n, 10, 64)
			if !ok || !ok2 || err != nil || q >= seq || !nsRe.MatchString(ns) || !ValidRequestID(id) {
				continue
			}
			if lock.Held(s.path("req", ns, id+".lock")) {
				blocked = true
				break
			}
			os.Remove(s.path("queue", app, e.Name())) // its runner is gone
		}
		if !blocked {
			return
		}
		time.Sleep(poll)
	}
}

// room: the namespace may take one more record; when it is full, its oldest done records older
// than Recent go first (under the store lock). Other namespaces are never touched.
func (s *Store) room() bool {
	ents, _ := os.ReadDir(s.path("req", s.NS))
	n := 0
	for _, e := range ents {
		if strings.HasSuffix(e.Name(), ".json") {
			n++
		}
	}
	if n < s.cap() {
		return true
	}
	type done struct {
		id  string
		fin int64
	}
	var old []done
	now := s.now()
	for _, e := range ents {
		id, ok := strings.CutSuffix(e.Name(), ".json")
		if !ok {
			continue
		}
		if r, ok := s.load(id); ok && r.State == "done" && now.Sub(time.Unix(r.Finished, 0)) > Recent {
			old = append(old, done{id, r.Finished})
		}
	}
	sort.Slice(old, func(i, j int) bool { return old[i].fin < old[j].fin })
	for _, d := range old {
		if n < s.cap() {
			break
		}
		if s.drop(s.NS, d.id) {
			n--
		}
	}
	return n < s.cap()
}

// prune removes done records older than Retention in every namespace (at most every pruneEvery;
// under the store lock).
func (s *Store) prune() {
	mark := s.path("pruned")
	if fi, err := os.Stat(mark); err == nil && s.now().Sub(fi.ModTime()) < pruneEvery {
		return
	}
	os.WriteFile(mark, nil, 0o600)
	now := s.now()
	os.Chtimes(mark, now, now)
	nss, _ := os.ReadDir(s.path("req"))
	for _, d := range nss {
		ns := d.Name()
		if !d.IsDir() || !nsRe.MatchString(ns) {
			continue
		}
		o := &Store{Dir: s.Dir, NS: ns}
		ents, _ := os.ReadDir(s.path("req", ns))
		for _, e := range ents {
			id, ok := strings.CutSuffix(e.Name(), ".json")
			if !ok {
				continue
			}
			if r, ok := o.load(id); ok && r.State == "done" && now.Sub(time.Unix(r.Finished, 0)) > Retention {
				s.drop(ns, id)
			}
		}
	}
}

func (s *Store) drop(ns, id string) bool {
	if lock.Held(s.path("req", ns, id+".lock")) {
		return false
	}
	os.Remove(s.path("req", ns, id+".json"))
	os.Remove(s.path("req", ns, id+".lock"))
	return true
}
