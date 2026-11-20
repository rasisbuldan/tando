package studio

import (
	"context"
	"errors"
	"sync"
	"time"

	"tando/srv/studio/pgwire"
)

// DB is what the studio needs of a PostgreSQL session (pgwire.Conn; a fake in tests, which
// records every call: the read-only wrapping is tested on that sequence).
type DB interface {
	Simple(sql string) error
	Exec(sql string, params [][]byte, maxRows int32, cellCap, rowCap int, sink pgwire.Sink) (pgwire.Result, error)
	TxStatus() byte
	Param(name string) string
	PID() uint32
	Cancel(ctx context.Context) error
	Kill()
	Close() error
}

// errBusy: the one connection is in use by another request (409)
var errBusy = errors.New("busy")

// errTxEnded: a statement ended the studio's transaction. With the allowlist this cannot
// happen; if it does, the batch stops here (the studio never begins a second transaction
// inside a batch: that would be one without a snapshot, which SET TRANSACTION could flip).
var errTxEnded = errors.New("transaction control is not available in read-only mode")

// conn: the studio's one connection to PostgreSQL, opened on first use, dropped when broken.
// mu is held by the request using it; another request gets errBusy (TryLock), never a wait.
type conn struct {
	mu   sync.Mutex
	dial func(ctx context.Context) (DB, error)
	db   DB
	used time.Time // the end of the last request (the connection is closed when idle)

	cmu     sync.Mutex // guards running
	running map[string]*txn
}

func (c *conn) get(ctx context.Context) (DB, error) {
	if c.db != nil {
		return c.db, nil
	}
	db, err := c.dial(ctx)
	if err != nil {
		return nil, err
	}
	c.db = db
	return db, nil
}

// idleClose: no request for d: the connection goes (the app gets its slot back and the backend
// its memory); the next request opens a new one
func (c *conn) idleClose(now time.Time, d time.Duration) {
	if d <= 0 || !c.mu.TryLock() {
		return
	}
	defer c.mu.Unlock()
	if c.db != nil && now.Sub(c.used) > d {
		c.db.Close()
		c.db = nil
	}
}

func (c *conn) drop() {
	if c.db != nil {
		c.db.Kill()
		c.db = nil
	}
}

// txn: one request's read-only transaction
type txn struct {
	s       *Studio
	db      DB
	ctx     context.Context
	id      string
	limit   time.Duration // one statement at most (the studio's clock)
	broken  bool
	cancels sync.WaitGroup
	timed   bool
	user    bool // cancelled by the user (/api/cancel)
	mu      sync.Mutex
	stmt    bool // a statement is running (a cancel has something to cancel)
}

// ro runs fn inside the studio's read-only transaction on the one connection:
//
//	BEGIN READ ONLY; SELECT 1   (one simple query of the studio's own: the snapshot is taken
//	                             before any user statement, so SET TRANSACTION READ WRITE and
//	                             set_config('transaction_read_only', ...) fail from here on)
//	fn                          (each statement a Parse/Bind/Execute of its own)
//	ROLLBACK, then DISCARD ALL  (session settings, advisory locks, prepared statements, temp
//	                             state: nothing outlives the request)
//
// A connection that misbehaves (a protocol error, a statement that would not stop) is dropped
// and opened again on the next request.
func (s *Studio) ro(ctx context.Context, id string, limit time.Duration, fn func(x *txn) error) error {
	if !s.c.mu.TryLock() {
		return errBusy
	}
	defer s.c.mu.Unlock()
	defer func() { s.c.used = s.cfg.Now() }()
	db, err := s.c.get(ctx)
	if err != nil {
		return err
	}
	if err := db.Simple("BEGIN READ ONLY; SELECT 1"); err != nil || db.TxStatus() != 'T' {
		s.c.drop()
		if err == nil {
			err = errors.New("could not start a read-only transaction")
		}
		return err
	}
	x := &txn{s: s, db: db, ctx: ctx, id: id, limit: limit}
	if id != "" {
		s.c.cmu.Lock()
		if s.c.running == nil {
			s.c.running = map[string]*txn{}
		}
		s.c.running[id] = x
		s.c.cmu.Unlock()
		defer func() { s.c.cmu.Lock(); delete(s.c.running, id); s.c.cmu.Unlock() }()
	}
	ferr := fn(x)
	x.cancels.Wait() // a cancel still on its way must not hit the ROLLBACK
	if x.broken {
		s.c.drop()
		return ferr
	}
	if err := db.Simple("ROLLBACK"); err != nil || db.TxStatus() != 'I' {
		s.c.drop()
	} else if err := db.Simple("DISCARD ALL"); err != nil {
		s.c.drop()
	}
	return ferr
}

// cancel: /api/cancel (and a request whose browser went away)
func (c *conn) cancel(id string) bool {
	c.cmu.Lock()
	x := c.running[id]
	c.cmu.Unlock()
	if x == nil {
		return false
	}
	x.mu.Lock()
	x.user = true
	x.mu.Unlock()
	x.cancel()
	return true
}

func (x *txn) cancel() {
	x.mu.Lock()
	defer x.mu.Unlock()
	if !x.stmt { // nothing running: a cancel now could hit the studio's own ROLLBACK
		return
	}
	x.cancels.Add(1) // (under mu: exec clears stmt under it, so Wait in ro comes after)
	go func() {
		defer x.cancels.Done()
		ctx, cf := context.WithTimeout(context.Background(), 3*time.Second)
		defer cf()
		x.db.Cancel(ctx)
	}()
}

// exec runs one statement under the studio's own clock: at the limit a CancelRequest, and if
// the statement has not stopped 5 s later the connection is closed. The limit holds whatever
// the session's statement_timeout says (any statement may SET it to 0).
func (x *txn) exec(sql string, params [][]byte, maxRows int32, cellCap, rowCap int, sink pgwire.Sink) (pgwire.Result, error) {
	limit := x.limit
	if dl, ok := x.ctx.Deadline(); ok {
		limit = min(limit, time.Until(dl))
	}
	if limit <= 0 {
		return pgwire.Result{Err: &pgwire.Error{Code: "57014", Message: "the request ran out of time"}}, nil
	}
	x.mu.Lock()
	x.stmt = true
	x.mu.Unlock()
	done := make(chan struct{})
	var kill *time.Timer
	var kmu sync.Mutex
	clock := time.AfterFunc(limit, func() {
		x.mu.Lock()
		x.timed = true
		x.mu.Unlock()
		x.cancel()
		kmu.Lock()
		kill = time.AfterFunc(x.s.killAfter, x.db.Kill)
		kmu.Unlock()
	})
	go func() {
		select {
		case <-x.ctx.Done():
			x.cancel()
		case <-done:
		}
	}()
	res, err := x.db.Exec(sql, params, maxRows, cellCap, rowCap, sink)
	close(done)
	clock.Stop()
	kmu.Lock()
	if kill != nil {
		kill.Stop()
	}
	kmu.Unlock()
	x.mu.Lock()
	x.stmt = false
	timed, user := x.timed, x.user
	x.mu.Unlock()
	if err != nil {
		x.broken = true
		if timed {
			return res, errors.New("the statement did not stop at the studio's time limit; the connection was closed")
		}
		return res, err
	}
	if res.Err != nil && res.Err.Code == "57014" {
		switch {
		case timed:
			res.Err.Message = "stopped: the statement ran longer than the studio's limit of " + x.limit.String()
		case user:
			res.Err.Message = "stopped (cancelled)"
		}
	}
	return res, nil
}
