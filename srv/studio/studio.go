// Package studio is `tando db studio`: a small web UI and SQL editor for an app's PostgreSQL
// database, served on a unix socket that the admin's own ssh connection forwards to the laptop
// (docs/COMMANDS.md, docs/ARCHITECTURE.md "db studio"). Read-only: every request runs in a
// read-only transaction whose snapshot is taken before the first user statement, statements
// other than queries are refused before they reach the server, and the studio's own clock stops
// a statement at the limit. It starts no program and listens on no network port.
package studio

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"tando/srv/studio/pgwire"
)

// Limits of v1 (docs/COMMANDS.md "tando db studio"): sizes are bytes of cell data.
const (
	DefaultRows  = 1000
	MaxRows      = 10000
	CellBytes    = 64 << 10 // a cell in the editor's results
	RowBytes     = 1 << 20  // a row in all
	RespBytes    = 8 << 20  // a response in all
	BrowseChars  = 16384    // a wide column in table browsing (left(c::text, 16385): one more means cut)
	BrowseBytea  = 8192     // a bytea cell in table browsing
	MaxSQL       = 256 << 10
	MaxStmts     = 100
	MaxBody      = 300 << 10
	CodeTTL      = 60 * time.Second
	DefaultLimit = 30 * time.Second
	BrowseLimit  = 10 * time.Second // table browsing: the studio's own queries
	ConnIdle     = 60 * time.Second // no request this long: the database connection is closed
	// SlotsFree: the studio connects only when this many connections stay free for the app (its
	// role's limit) and for the server (max_connections less the superuser's) after it does
	SlotsFree = 2
)

// Config: what main read from the flags and the credential file.
type Config struct {
	App, Host, Admin string // the app, the host's name in tando (for the page), the admin's login
	Role, Database   string
	Password         string
	Port             int           // the laptop's port: the only Host the page may come with
	Idle             time.Duration // no API request for this long: stop
	Heartbeat        time.Duration // the client sends a byte this often; 4.5 of them missed: stop
	StmtLimit        time.Duration // one statement at most (the studio's own clock)
	ConnIdle         time.Duration // the database connection is closed after this long unused
	PGAddr           string
	Out              io.Writer // stdout: the ready and stopped lines, nothing else
	Log              io.Writer // stderr (the journal): start, stop, internal errors
	Dial             func(ctx context.Context) (DB, error)
	Now              func() time.Time
}

// Studio is one session.
type Studio struct {
	cfg     Config
	c       conn
	token   string
	code    string
	codeAt  time.Time
	codeUse atomic.Bool
	probe   string
	pgver   string
	hkey    string
	life    life
	stmts   atomic.Int64
	omu     sync.Mutex // stdout: the ready, backend and stopped lines
	stop    chan string
	once    sync.Once
	static  map[string]asset
	// killAfter: a statement still running this long after its CancelRequest has its
	// connection closed (5 s; tests shorten it)
	killAfter time.Duration
	types     sync.Map // oid -> type name (format_type), filled as results need it
}

// startupParams: every studio connection's settings (source "client": they override the role's
// ALTER ROLE ... SET). default_transaction_read_only is a second layer under the studio's own
// BEGIN READ ONLY; the timeouts are a second layer under the studio's clock.
func startupParams(c Config) [][2]string {
	return [][2]string{
		{"application_name", cut("tando studio ("+c.Admin+")", 60)},
		{"default_transaction_read_only", "on"},
		// (2 s after the studio's own clock, which is the limit: this is the layer under it)
		{"statement_timeout", fmt.Sprintf("%dms", (c.StmtLimit + 2*time.Second).Milliseconds())},
		{"lock_timeout", "2s"},
		{"idle_in_transaction_session_timeout", "60s"},
		// the backend's memory: one sort or hash node at most 2 MB before it spills to a temp
		// file (the role's temp_file_limit, 1 GB, is a superuser setting: it stays); one process
		// (no parallel workers), no JIT (its compile memory and CPU). DISCARD ALL after every
		// request puts these back (they are the session's start values); SET of them and
		// set_config are refused (sqlsplit)
		{"work_mem", "2MB"},
		{"hash_mem_multiplier", "1"},
		{"max_parallel_workers_per_gather", "0"},
		{"max_parallel_workers", "0"},
		{"temp_buffers", "1MB"},
		{"jit", "off"},
		{"client_encoding", "UTF8"},
		{"DateStyle", "ISO"},
		{"IntervalStyle", "postgres"},
		{"extra_float_digits", "3"},
		{"bytea_output", "hex"},
	}
}

func cut(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}

// PGDial is the real connection (127.0.0.1:5432 as the app's role).
func PGDial(c Config) func(ctx context.Context) (DB, error) {
	return func(ctx context.Context) (DB, error) {
		ctx, cf := context.WithTimeout(ctx, 10*time.Second)
		defer cf()
		db, err := pgwire.Connect(ctx, pgwire.Config{Addr: c.PGAddr, User: c.Role, Database: c.Database,
			Password: c.Password, Params: startupParams(c)})
		if err != nil {
			return nil, dbErr(err)
		}
		return db, nil
	}
}

// dbErr: why the studio cannot reach the database, in the user's words
func dbErr(err error) error {
	var e *pgwire.Error
	if errors.As(err, &e) {
		switch e.Code {
		case "53300":
			return errors.New("the app holds all of its database connections; the studio needs one (tando db shows them)")
		case "28P01":
			return errors.New("PostgreSQL refused the app's password (DATABASE_URL in the app's env differs from the role's)")
		case "57P03":
			return errors.New("PostgreSQL is starting or shutting down: try again in a moment")
		}
		return fmt.Errorf("PostgreSQL refused the connection: %s", e.Message)
	}
	var ne *net.OpError
	if errors.As(err, &ne) {
		return errors.New("PostgreSQL does not answer on 127.0.0.1:5432 (tando doctor)")
	}
	return err
}

func rnd(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b)
}

// HistoryKey: the key the page encrypts its SQL history and draft with (AES-GCM, in the
// browser's localStorage). Derived from the role's password: no new secret, nothing stored on
// the server; a new password orphans the old history.
func HistoryKey(password, app string) string {
	m := hmac.New(sha256.New, []byte(password))
	m.Write([]byte("tando studio history " + app))
	return base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}

// New checks the configuration and connects once (the version for the page, and a login that
// fails here fails before the browser opens).
func New(ctx context.Context, cfg Config) (*Studio, error) {
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.StmtLimit <= 0 {
		cfg.StmtLimit = DefaultLimit
	}
	if cfg.Dial == nil {
		cfg.Dial = PGDial(cfg)
	}
	if cfg.Port < 1024 || cfg.Port > 65535 {
		return nil, errors.New("bad port")
	}
	s := &Studio{cfg: cfg, token: rnd(32), code: rnd(32), probe: rnd(8), stop: make(chan string, 1),
		hkey: HistoryKey(cfg.Password, cfg.App), killAfter: 5 * time.Second}
	if cfg.ConnIdle == 0 {
		s.cfg.ConnIdle = ConnIdle
	}
	s.c.dial = s.dial
	s.static = assets()
	now := cfg.Now()
	s.codeAt = now
	s.life = life{beat: now, active: now, idle: cfg.Idle, hb: cfg.Heartbeat * 9 / 2}
	db, err := s.c.get(ctx)
	if err != nil {
		return nil, err
	}
	s.pgver = db.Param("server_version")
	if v, _, ok := strings.Cut(s.pgver, " "); ok {
		s.pgver = v
	}
	return s, nil
}

// life: when the session ends by itself. Pure (the clock is passed in), so it is tested with a
// fake one; Serve drives it with a ticker.
type life struct {
	mu           sync.Mutex
	beat, active time.Time
	idle, hb     time.Duration
	eof          bool
}

func (l *life) heartbeat(now time.Time) { l.mu.Lock(); l.beat = now; l.mu.Unlock() }
func (l *life) touch(now time.Time)     { l.mu.Lock(); l.active = now; l.mu.Unlock() }
func (l *life) closed()                 { l.mu.Lock(); l.eof = true; l.mu.Unlock() }

// reason: why the session must end now, "" when it goes on
func (l *life) reason(now time.Time) string {
	l.mu.Lock()
	defer l.mu.Unlock()
	switch {
	case l.eof:
		return "eof"
	case l.hb > 0 && now.Sub(l.beat) > l.hb:
		return "heartbeat"
	case l.idle > 0 && now.Sub(l.active) > l.idle:
		return "idle"
	}
	return ""
}

// say writes a line on stdout (the agent's relay reads it)
func (s *Studio) say(f string, a ...any) {
	s.omu.Lock()
	fmt.Fprintf(s.cfg.Out, f+"\n", a...)
	s.omu.Unlock()
}

// slotsSQL: the role's and the server's connections in use (this one included) and their limits
const slotsSQL = `SELECT (SELECT count(*) FROM pg_stat_activity WHERE usename = current_user),
  (SELECT rolconnlimit FROM pg_roles WHERE rolname = current_user),
  (SELECT count(*) FROM pg_stat_activity WHERE usename IS NOT NULL),
  current_setting('max_connections')::int - current_setting('superuser_reserved_connections')::int`

// dial opens the connection, leaves it again when the app (or the server) would be left with
// fewer than SlotsFree connections, and says the backend's pid: the root agent checks that pid
// is this app's studio backend and lowers its CPU and I/O priority (docs/ARCHITECTURE.md)
func (s *Studio) dial(ctx context.Context) (DB, error) {
	db, err := s.cfg.Dial(ctx)
	if err != nil {
		return nil, err
	}
	c := &collect{}
	r, err := db.Exec(slotsSQL, nil, 0, 100, 1000, c)
	if err != nil || r.Err != nil || len(c.rows) != 1 || len(c.rows[0]) != 4 {
		db.Kill()
		return nil, errors.New("could not count the database connections")
	}
	row := c.rows[0]
	used, lim, all, max := i64(row[0]), i64(row[1]), i64(row[2]), i64(row[3])
	if lim >= 0 && lim-used < SlotsFree {
		db.Close()
		return nil, fmt.Errorf("the app uses %d of its %d database connections; the studio needs one and leaves %d free for the app: try again when it uses fewer (tando db)", used-1, lim, SlotsFree)
	}
	if max > 0 && max-all < SlotsFree {
		db.Close()
		return nil, fmt.Errorf("PostgreSQL on this server has %d of its %d connections in use; the studio leaves %d free: try again later", all-1, max, SlotsFree)
	}
	s.say("backend pid=%d", db.PID())
	return db, nil
}

// End stops the session (first reason wins).
func (s *Studio) End(reason string) {
	select {
	case s.stop <- reason:
	default:
	}
}

// Ready is the line the client waits for (stdout); the code is single-use (POST /api/session).
func (s *Studio) Ready() string {
	return fmt.Sprintf("ready code=%s probe=%s mode=ro pg=%s", s.code, s.probe, safeWord(s.pgver))
}

func safeWord(v string) string {
	var b strings.Builder
	for _, r := range v {
		if r >= '0' && r <= '9' || r == '.' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' {
			b.WriteRune(r)
		}
	}
	return cut(b.String(), 20)
}

// Serve answers on ln until the session ends; stdin carries the client's heartbeat (EOF: the
// ssh session is gone). Returns the reason.
func (s *Studio) Serve(ln net.Listener, stdin io.Reader, tick time.Duration) string {
	srv := &http.Server{Handler: s, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second,
		WriteTimeout: 2*s.cfg.StmtLimit + 30*time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16 << 10,
		ErrorLog: nil}
	go func() {
		buf := make([]byte, 64)
		for {
			n, err := stdin.Read(buf)
			if n > 0 {
				s.life.heartbeat(s.cfg.Now())
			}
			if err != nil {
				s.life.closed()
				s.End("eof")
				return
			}
		}
	}()
	go srv.Serve(ln)
	s.say("%s", s.Ready())
	t := time.NewTicker(tick)
	defer t.Stop()
	var reason string
loop:
	for {
		select {
		case reason = <-s.stop:
			break loop
		case <-t.C:
			now := s.cfg.Now()
			if r := s.life.reason(now); r != "" {
				reason = r
				break loop
			}
			s.c.idleClose(now, s.cfg.ConnIdle)
		}
	}
	// stop accepting, stop what runs, say Terminate, the socket goes with the listener
	ln.Close()
	s.c.cmu.Lock()
	for _, x := range s.c.running {
		x.cancel()
	}
	s.c.cmu.Unlock()
	ctx, cf := context.WithTimeout(context.Background(), 3*time.Second)
	srv.Shutdown(ctx)
	cf()
	if s.c.mu.TryLock() {
		if s.c.db != nil {
			s.c.db.Close()
			s.c.db = nil
		}
		s.c.mu.Unlock()
	} else {
		s.c.drop() // a request still holds it: close the socket under it
	}
	s.say("stopped reason=%s queries=%d", reason, s.stmts.Load())
	return reason
}

// Listen makes the unix socket: the directory (made by the agent, the admin's and the app's
// group's only) is the access rule, so the socket itself is 0666.
func Listen(path string) (net.Listener, error) {
	os.Remove(path)
	ln, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(path, 0o666); err != nil {
		ln.Close()
		return nil, err
	}
	return ln, nil
}
