package ctl

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
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
//	req/<id>.json         the record: the request's digest, app, seq, state (pending|done) and,
//	                      when done, the response; written (fsynced) before the request runs
//	req/<id>.lock         held by the process running the request, for as long as it runs: a
//	                      retry waits on it; a pending record whose lock nobody holds was cut off
//	queue/<app>/<seq>-<id>  a request of that app waiting or running; removed when it is done
//
// A retry with the same id and the same request gets the first response, waiting for it while
// the first is still running; the same id with a different request is refused (conflict). Done
// records are kept for Retention (and at most MaxRecords), then removed.
//
// New verbs (artifact deploy, hold, apply, drain) plug in as a verb whose run function does the
// work: the store neither knows nor cares what a request does.

const (
	Retention  = 7 * 24 * time.Hour
	MaxRecords = 20000
	pruneEvery = 10 * time.Minute
)

// Store is the request store in Dir.
type Store struct {
	Dir string
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

// Digest identifies a request's content: verb, app and arguments (compacted). The arguments can
// hold secrets (env values): only this hash is kept.
func Digest(r Request) string {
	h := sha256.New()
	fmt.Fprintf(h, "%s\x00%s\x00", r.Verb, r.App)
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

func (s *Store) init() error {
	for _, d := range []string{s.Dir, s.path("req"), s.path("queue")} {
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
	b, err := os.ReadFile(s.path("req", id+".json"))
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
	return atomicfile.Write(s.path("req", r.ID+".json"), append(b, '\n'), atomicfile.Mode(0o600))
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
	dg := Digest(req)
	sl, err := lock.Acquire(s.path("store.lock"), 30*time.Second)
	if err != nil {
		return fail(req, "busy", errBusyStore.Error()+": try again")
	}
	rec, seen := s.load(req.RequestID)
	if seen {
		sl.Release()
		if rec.Digest != dg {
			return fail(req, "conflict", "request_id "+req.RequestID+" was used for a different request ("+rec.Verb+"): use a new id")
		}
		return s.await(req, rec, wait)
	}
	held, err := lock.Acquire(s.path("req", req.RequestID+".lock"), 0)
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
		q = filepath.Join(qd, fmt.Sprintf("%016d-%s", seq, req.RequestID))
		if err = os.MkdirAll(qd, 0o700); err == nil {
			err = os.WriteFile(q, nil, 0o600)
		}
	}
	sl.Release()
	if err != nil {
		os.Remove(s.path("req", req.RequestID+".json"))
		return fail(req, "internal", "the request store cannot be written: "+err.Error())
	}
	s.waitTurn(req.App, seq)
	resp := run()
	resp.RequestID = req.RequestID
	rec.State, rec.Finished, rec.Response = "done", s.now().Unix(), &resp
	if sl, err = lock.Acquire(s.path("store.lock"), 5*time.Minute); err == nil {
		if err := s.save(rec); err != nil {
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
func (s *Store) await(req Request, rec record, wait time.Duration) Response {
	if rec.State != "done" {
		l, err := lock.Acquire(s.path("req", req.RequestID+".lock"), wait)
		if err != nil {
			return fail(req, "pending", "request "+req.RequestID+" is still running: ask again with the same request_id")
		}
		l.Release()
		r, ok := s.load(req.RequestID)
		if !ok {
			return fail(req, "internal", "the record of request "+req.RequestID+" is gone")
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
		os.Remove(s.path("queue", r.App, fmt.Sprintf("%016d-%s", r.Seq, r.ID)))
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
			n, id, ok := strings.Cut(e.Name(), "-")
			q, err := strconv.ParseInt(n, 10, 64)
			if !ok || err != nil || q >= seq {
				continue
			}
			if lock.Held(s.path("req", id+".lock")) {
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

// prune removes done records older than Retention, then the oldest done ones over MaxRecords
// (at most every pruneEvery; under the store lock).
func (s *Store) prune() {
	mark := s.path("pruned")
	if fi, err := os.Stat(mark); err == nil && s.now().Sub(fi.ModTime()) < pruneEvery {
		return
	}
	os.WriteFile(mark, nil, 0o600)
	now := s.now()
	os.Chtimes(mark, now, now)
	ents, _ := os.ReadDir(s.path("req"))
	type done struct {
		id  string
		fin int64
	}
	var keep []done
	for _, e := range ents {
		id, ok := strings.CutSuffix(e.Name(), ".json")
		if !ok {
			continue
		}
		r, ok := s.load(id)
		if !ok || r.State != "done" {
			continue
		}
		if now.Sub(time.Unix(r.Finished, 0)) > Retention {
			s.drop(id)
			continue
		}
		keep = append(keep, done{id, r.Finished})
	}
	if len(keep) > MaxRecords {
		sort.Slice(keep, func(i, j int) bool { return keep[i].fin < keep[j].fin })
		for _, d := range keep[:len(keep)-MaxRecords] {
			s.drop(d.id)
		}
	}
}

func (s *Store) drop(id string) {
	if lock.Held(s.path("req", id+".lock")) {
		return
	}
	os.Remove(s.path("req", id+".json"))
	os.Remove(s.path("req", id+".lock"))
}
