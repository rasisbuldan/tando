// Package pgwire is the studio's PostgreSQL client: protocol 3.0 over one TCP connection, the
// SCRAM-SHA-256 login only, the simple query for the studio's own statements and Parse/Bind/
// Describe/Execute/Sync (text format) for everything else. Parse takes exactly one command, which
// is what makes the read-only mode enforceable (see srv/studio). TLS when Config.TLS is set (a
// database on a data node: the session and the cancel request both negotiate it), no COPY
// (refused), no other login method (refused with a message that names tando db psql).
//
// Every message is length-checked (MaxMessage) except DataRow, which is read as a stream: each
// cell is cut at the caller's cap and the rest of it is discarded from the socket, so a 100 MB
// cell costs a 64 KiB buffer, not 100 MB.
package pgwire

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"slices"
	"strings"
	"time"
)

// MaxMessage bounds every message but DataRow (RowDescription of 1,600 columns is ~130 KB).
const MaxMessage = 8 << 20

// Config says where and as whom to connect. Params are the startup parameters after user and
// database, in order (any run-time setting can be one: statement_timeout, application_name ...).
type Config struct {
	Addr     string
	User     string
	Database string
	Password string
	Params   [][2]string
	// TLS: negotiate TLS first (SSLRequest) and refuse a server that does not offer it; the
	// config's RootCAs and ServerName are what verify-full checks
	TLS *tls.Config
	// Dial replaces net.Dialer for tests (the cancel request uses it too)
	Dial func(ctx context.Context, addr string) (net.Conn, error)
	// scramUser: the name in SCRAM's client-first message; PostgreSQL ignores it (empty, as
	// libpq sends), the RFC 7677 test vector needs "user"
	scramUser string
	nonce     string // tests: a fixed client nonce
}

// Error is an ErrorResponse: the statement failed, the connection is fine.
type Error struct {
	Severity, Code, Message, Detail, Hint string
	Position                              int // 1-based character position in the statement, 0 when none
}

func (e *Error) Error() string { return e.Message }

// Notice is a NoticeResponse (or a warning).
type Notice struct{ Severity, Message string }

// Field is one column of a RowDescription.
type Field struct {
	Name    string
	Table   uint32
	Column  int16
	TypeOID uint32
	TypLen  int16
	TypeMod int32
}

// Sink receives a statement's result as it arrives. Columns comes first (nil for a statement
// without rows). In Row, a nil cell is NULL and full[i] is the cell's length in bytes when it was
// cut (else -1); the slices are reused after Row returns. Returning ErrStop from Row stops
// delivery: the rest of the result is read and dropped, and Exec reports Stopped.
type Sink interface {
	Columns([]Field) error
	Row(cells [][]byte, full []int) error
}

// ErrStop is returned by a Sink to stop receiving rows.
var ErrStop = errors.New("stop")

// Result is what one Exec returned besides the rows.
type Result struct {
	Tag       string // CommandComplete's tag ("SELECT 3"), empty for an empty query
	Suspended bool   // Execute's row limit was reached (more rows may follow)
	Stopped   bool   // the Sink returned ErrStop
	Err       *Error // the statement failed
	Notices   []Notice
	Copy      bool // the statement was a COPY (refused)
}

// Conn is one session. It is used by one goroutine at a time, except Cancel and Kill.
type Conn struct {
	cfg    Config
	nc     net.Conn
	r      *bufio.Reader
	wb     []byte
	pid    uint32
	key    uint32
	tx     byte
	params map[string]string
	notes  []Notice
	hdr    [5]byte
	cell   []byte
}

// ProtocolError means the connection is unusable: the caller drops it.
type ProtocolError struct{ msg string }

func (e *ProtocolError) Error() string { return "postgresql protocol: " + e.msg }

func perr(f string, a ...any) error { return &ProtocolError{fmt.Sprintf(f, a...)} }

func dial(cfg *Config, ctx context.Context) (net.Conn, error) {
	var nc net.Conn
	var err error
	if cfg.Dial != nil {
		nc, err = cfg.Dial(ctx, cfg.Addr)
	} else {
		var d net.Dialer
		nc, err = d.DialContext(ctx, "tcp", cfg.Addr)
	}
	if err != nil || cfg.TLS == nil {
		return nc, err
	}
	if dl, ok := ctx.Deadline(); ok {
		nc.SetDeadline(dl)
	}
	// SSLRequest: length 8, code 80877103; the server answers one byte, S or N
	var b [1]byte
	if _, err = nc.Write([]byte{0, 0, 0, 8, 4, 210, 22, 47}); err == nil {
		_, err = io.ReadFull(nc, b[:])
	}
	if err == nil && b[0] != 'S' {
		err = errors.New("the database server does not offer TLS")
	}
	if err != nil {
		nc.Close()
		return nil, err
	}
	tc := tls.Client(nc, cfg.TLS)
	if err := tc.HandshakeContext(ctx); err != nil {
		nc.Close()
		return nil, err
	}
	nc.SetDeadline(time.Time{})
	return tc, nil
}

// Connect opens a session and logs in.
func Connect(ctx context.Context, cfg Config) (*Conn, error) {
	for _, p := range append([][2]string{{cfg.User, cfg.Database}}, cfg.Params...) {
		if strings.IndexByte(p[0]+p[1], 0) >= 0 {
			return nil, errors.New("a startup parameter has a NUL byte")
		}
	}
	nc, err := dial(&cfg, ctx)
	if err != nil {
		return nil, err
	}
	c := &Conn{cfg: cfg, nc: nc, r: bufio.NewReaderSize(nc, 32<<10), params: map[string]string{}}
	if dl, ok := ctx.Deadline(); ok {
		nc.SetDeadline(dl)
	}
	if err := c.startup(); err != nil {
		nc.Close()
		return nil, err
	}
	nc.SetDeadline(time.Time{})
	return c, nil
}

func (c *Conn) startup() error {
	b := []byte{0, 0, 0, 0, 0, 3, 0, 0}
	kv := append([][2]string{{"user", c.cfg.User}, {"database", c.cfg.Database}}, c.cfg.Params...)
	for _, p := range kv {
		b = append(append(append(append(b, p[0]...), 0), p[1]...), 0)
	}
	b = append(b, 0)
	binary.BigEndian.PutUint32(b, uint32(len(b)))
	if _, err := c.nc.Write(b); err != nil {
		return err
	}
	var sc *scram
	for {
		t, body, err := c.read()
		if err != nil {
			return err
		}
		switch t {
		case 'R':
			if len(body) < 4 {
				return perr("short authentication message")
			}
			code := binary.BigEndian.Uint32(body)
			switch code {
			case 0:
			case 10: // SASL: the mechanisms offered
				if !hasMech(body[4:], "SCRAM-SHA-256") {
					return errors.New("the server offers no SCRAM-SHA-256 login; the studio needs it (tando db psql works)")
				}
				sc = newScram(c.cfg.scramUser, c.cfg.Password, c.cfg.nonce)
				first := sc.first()
				m := c.msg('p')
				m = append(append(m, "SCRAM-SHA-256"...), 0)
				m = binary.BigEndian.AppendUint32(m, uint32(len(first)))
				c.wb = append(m, first...)
				if err := c.flush(); err != nil {
					return err
				}
			case 11:
				if sc == nil {
					return perr("SASL continue without a start")
				}
				final, err := sc.final(body[4:])
				if err != nil {
					return err
				}
				c.wb = append(c.msg('p'), final...)
				if err := c.flush(); err != nil {
					return err
				}
			case 12:
				if sc == nil || !sc.verify(body[4:]) {
					return errors.New("the server's SCRAM signature does not match: not the PostgreSQL expected")
				}
				sc.done = true
			case 3, 5:
				return errors.New("the role's password is not a SCRAM verifier (password_encryption = md5?): use tando db psql")
			default:
				return fmt.Errorf("the server asks for a login method the studio does not support (%d): use tando db psql", code)
			}
			if code == 0 && sc != nil && !sc.done {
				return errors.New("the server accepted the login without proving it knows the password")
			}
		case 'K':
			if len(body) != 8 {
				return perr("BackendKeyData of %d bytes", len(body))
			}
			c.pid, c.key = binary.BigEndian.Uint32(body), binary.BigEndian.Uint32(body[4:])
		case 'v':
			return errors.New("the server wants another protocol version (NegotiateProtocolVersion)")
		case 'Z':
			if sc == nil && c.cfg.Password != "" {
				return errors.New("the server let the studio in without a password (trust in pg_hba.conf?): refused")
			}
			return c.ready(body)
		default:
			if err := c.async(t, body); err != nil {
				return err
			}
		}
	}
}

func hasMech(b []byte, want string) bool {
	for _, m := range strings.Split(string(b), "\x00") {
		if m == want {
			return true
		}
	}
	return false
}

// read returns one message whole (not DataRow: see execute).
func (c *Conn) read() (byte, []byte, error) {
	t, n, err := c.header()
	if err != nil {
		return 0, nil, err
	}
	body := make([]byte, n)
	if _, err := io.ReadFull(c.r, body); err != nil {
		return 0, nil, err
	}
	return t, body, nil
}

func (c *Conn) header() (byte, int, error) {
	if _, err := io.ReadFull(c.r, c.hdr[:]); err != nil {
		return 0, 0, err
	}
	n := int(binary.BigEndian.Uint32(c.hdr[1:])) - 4
	if n < 0 || n > MaxMessage && c.hdr[0] != 'D' && c.hdr[0] != 'd' {
		return 0, 0, perr("message %q of %d bytes", c.hdr[0], n)
	}
	return c.hdr[0], n, nil
}

// async handles what may arrive at any time; anything else is a protocol error.
func (c *Conn) async(t byte, body []byte) error {
	switch t {
	case 'S':
		k, v, _ := strings.Cut(string(body), "\x00")
		c.params[k] = strings.TrimSuffix(v, "\x00")
	case 'N':
		if len(c.notes) < 100 {
			f := fields(body)
			c.notes = append(c.notes, Notice{Severity: f['S'], Message: cut(f['M'], 2000)})
		}
	case 'A': // NotificationResponse: LISTEN is refused in the studio; dropped
	case 'E':
		return errFrom(body)
	default:
		return perr("unexpected message %q", t)
	}
	return nil
}

func (c *Conn) ready(body []byte) error {
	if len(body) != 1 || !strings.ContainsRune("ITE", rune(body[0])) {
		return perr("bad ReadyForQuery")
	}
	c.tx = body[0]
	return nil
}

func cut(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}

func fields(b []byte) map[byte]string {
	f := map[byte]string{}
	for len(b) > 1 {
		k := b[0]
		i := 1
		for i < len(b) && b[i] != 0 {
			i++
		}
		f[k] = string(b[1:i])
		if i >= len(b) {
			break
		}
		b = b[i+1:]
	}
	return f
}

func errFrom(body []byte) *Error {
	f := fields(body)
	e := &Error{Severity: f['S'], Code: f['C'], Message: cut(f['M'], 4000), Detail: cut(f['D'], 4000), Hint: cut(f['H'], 4000)}
	if f['V'] != "" {
		e.Severity = f['V']
	}
	for _, ch := range f['P'] {
		if ch < '0' || ch > '9' || e.Position > 1e8 {
			e.Position = 0
			break
		}
		e.Position = e.Position*10 + int(ch-'0')
	}
	return e
}

func (c *Conn) msg(t byte) []byte { return append(c.wb[:0], t, 0, 0, 0, 0) }

// end fills in the length of the message that starts at off
func end(b []byte, off int) []byte {
	binary.BigEndian.PutUint32(b[off+1:], uint32(len(b)-off-1))
	return b
}

func (c *Conn) flush() error {
	c.wb = end(c.wb, 0)
	_, err := c.nc.Write(c.wb)
	return err
}

// TxStatus is the transaction status of the last ReadyForQuery: 'I' idle, 'T' in a transaction
// block, 'E' in a failed one.
func (c *Conn) TxStatus() byte { return c.tx }

// Param is a ParameterStatus value (server_version, standard_conforming_strings ...).
func (c *Conn) Param(k string) string { return c.params[k] }

// PID is the backend's process id (BackendKeyData).
func (c *Conn) PID() uint32 { return c.pid }

// Simple runs a simple query of the studio's own (never user text: a simple query may hold
// several commands) and returns its first error. Rows are dropped.
func (c *Conn) Simple(sql string) error {
	if strings.IndexByte(sql, 0) >= 0 {
		return errors.New("NUL in a statement")
	}
	c.wb = append(append(c.msg('Q'), sql...), 0)
	if err := c.flush(); err != nil {
		return err
	}
	var first *Error
	for {
		t, n, err := c.header()
		if err != nil {
			return err
		}
		if t == 'D' || t == 'd' {
			if _, err := c.r.Discard(n); err != nil {
				return err
			}
			continue
		}
		body := make([]byte, n)
		if _, err := io.ReadFull(c.r, body); err != nil {
			return err
		}
		switch t {
		case 'T', 'C', 'I', 'n':
		case 'G': // COPY FROM STDIN in a studio statement: never, but answer it
			if err := c.copyFail(false); err != nil {
				return err
			}
		case 'H', 'c':
		case 'E':
			if first == nil {
				first = errFrom(body)
			}
		case 'Z':
			if err := c.ready(body); err != nil {
				return err
			}
			if first != nil {
				return first
			}
			return nil
		default:
			if err := c.async(t, body); err != nil {
				return err
			}
		}
	}
}

// copyFail answers CopyInResponse. In the extended protocol the Sync sent with Execute was
// ignored during copy-in, and the server now waits for one; a simple query needs none.
func (c *Conn) copyFail(sync bool) error {
	c.wb = append(append(c.msg('f'), "COPY is not supported in the studio: tando db psql"...), 0)
	c.wb = end(c.wb, 0)
	if sync {
		off := len(c.wb)
		c.wb = end(append(c.wb, 'S', 0, 0, 0, 0), off)
	}
	_, err := c.nc.Write(c.wb)
	return err
}

// Exec runs one statement with the extended protocol: Parse (unnamed; the server refuses a
// string with two commands), Bind (text values, nil is NULL), Describe, Execute(maxRows; 0 is
// all), Sync. Cells longer than cellCap bytes are cut (the rest is discarded); a row keeps at
// most rowCap bytes in all. An SQL error is in Result.Err; an error return means the connection
// is unusable.
func (c *Conn) Exec(sql string, params [][]byte, maxRows int32, cellCap, rowCap int, sink Sink) (res Result, err error) {
	if strings.IndexByte(sql, 0) >= 0 {
		res.Err = &Error{Code: "22021", Message: "the statement has a NUL character"}
		return res, nil
	}
	if len(params) > 65535 {
		return res, errors.New("too many parameters")
	}
	m := c.msg('P')
	m = append(append(append(m, 0), sql...), 0, 0, 0)
	m = end(m, 0)
	off := len(m)
	m = append(m, 'B', 0, 0, 0, 0, 0, 0, 0, 0)
	m = binary.BigEndian.AppendUint16(m, uint16(len(params)))
	for _, p := range params {
		if p == nil {
			m = binary.BigEndian.AppendUint32(m, 0xffffffff)
		} else {
			m = binary.BigEndian.AppendUint32(m, uint32(len(p)))
			m = append(m, p...)
		}
	}
	m = append(m, 0, 0)
	m = end(m, off)
	off = len(m)
	m = end(append(m, 'D', 0, 0, 0, 0, 'P', 0), off)
	off = len(m)
	m = append(m, 'E', 0, 0, 0, 0, 0)
	m = binary.BigEndian.AppendUint32(m, uint32(maxRows))
	m = end(m, off)
	off = len(m)
	c.wb = end(append(m, 'S', 0, 0, 0, 0), off)
	if _, err := c.nc.Write(c.wb); err != nil {
		return res, err
	}
	c.notes = c.notes[:0]
	defer func() { res.Notices = append([]Notice(nil), c.notes...) }()
	var cells [][]byte
	var full []int
	for {
		t, n, err := c.header()
		if err != nil {
			return res, err
		}
		if t == 'D' {
			if err := c.dataRow(n, cellCap, rowCap, &cells, &full); err != nil {
				return res, err
			}
			if !res.Stopped && res.Err == nil {
				if err := sink.Row(cells, full); err == ErrStop {
					res.Stopped = true
				} else if err != nil {
					return res, err
				}
			}
			continue
		}
		if t == 'd' { // CopyData of a COPY TO STDOUT: drained
			if _, err := c.r.Discard(n); err != nil {
				return res, err
			}
			continue
		}
		body := make([]byte, n)
		if _, err := io.ReadFull(c.r, body); err != nil {
			return res, err
		}
		switch t {
		case '1', '2', '3':
		case 'T':
			fs, err := rowDesc(body)
			if err != nil {
				return res, err
			}
			if err := sink.Columns(fs); err != nil {
				return res, err
			}
		case 'n':
			if err := sink.Columns(nil); err != nil {
				return res, err
			}
		case 'C':
			res.Tag = strings.TrimSuffix(string(body), "\x00")
		case 'I':
		case 's':
			res.Suspended = true
		case 'G':
			res.Copy = true
			if err := c.copyFail(true); err != nil {
				return res, err
			}
		case 'H':
			res.Copy = true
		case 'c':
		case 'E':
			if res.Err == nil {
				res.Err = errFrom(body)
			}
		case 'Z':
			if err := c.ready(body); err != nil {
				return res, err
			}
			if res.Copy && res.Err == nil {
				res.Err = &Error{Code: "0A000", Message: "COPY is not supported in the studio: tando db psql"}
			}
			return res, nil
		default:
			if err := c.async(t, body); err != nil {
				return res, err
			}
		}
	}
}

func rowDesc(b []byte) ([]Field, error) {
	if len(b) < 2 {
		return nil, perr("short RowDescription")
	}
	n := int(binary.BigEndian.Uint16(b))
	b = b[2:]
	fs := make([]Field, 0, min(n, 2000))
	for range n {
		i := 0
		for i < len(b) && b[i] != 0 {
			i++
		}
		if i+19 > len(b) {
			return nil, perr("short RowDescription field")
		}
		f := Field{Name: string(b[:i])}
		b = b[i+1:]
		f.Table = binary.BigEndian.Uint32(b)
		f.Column = int16(binary.BigEndian.Uint16(b[4:]))
		f.TypeOID = binary.BigEndian.Uint32(b[6:])
		f.TypLen = int16(binary.BigEndian.Uint16(b[10:]))
		f.TypeMod = int32(binary.BigEndian.Uint32(b[12:]))
		b = b[18:]
		fs = append(fs, f)
	}
	return fs, nil
}

// dataRow reads one DataRow of n bytes from the stream, keeping at most cellCap bytes of a
// cell and rowCap of the row; what is not kept is discarded from the socket.
func (c *Conn) dataRow(n, cellCap, rowCap int, cells *[][]byte, full *[]int) error {
	if n < 2 {
		return perr("short DataRow")
	}
	var h [4]byte
	if _, err := io.ReadFull(c.r, h[:2]); err != nil {
		return err
	}
	n -= 2
	nc := int(binary.BigEndian.Uint16(h[:]))
	*cells, *full = (*cells)[:0], (*full)[:0]
	c.cell = c.cell[:0]
	type span struct{ off, n int }
	var spans [64]span
	sp := spans[:0]
	for range nc {
		if n < 4 {
			return perr("DataRow shorter than its cells")
		}
		if _, err := io.ReadFull(c.r, h[:]); err != nil {
			return err
		}
		n -= 4
		l := int(int32(binary.BigEndian.Uint32(h[:])))
		if l < 0 {
			sp = append(sp, span{-1, 0})
			*full = append(*full, -1)
			continue
		}
		if l > n {
			return perr("DataRow cell of %d bytes in %d", l, n)
		}
		keep := min(l, cellCap, max(rowCap-len(c.cell), 0))
		off := len(c.cell)
		c.cell = slices.Grow(c.cell, keep)[:off+keep]
		if _, err := io.ReadFull(c.r, c.cell[off:]); err != nil {
			return err
		}
		if l > keep {
			if _, err := c.r.Discard(l - keep); err != nil {
				return err
			}
			*full = append(*full, l)
		} else {
			*full = append(*full, -1)
		}
		n -= l
		sp = append(sp, span{off, keep})
	}
	if n != 0 {
		return perr("DataRow longer than its cells")
	}
	for _, s := range sp {
		if s.off < 0 {
			*cells = append(*cells, nil)
		} else {
			*cells = append(*cells, c.cell[s.off:s.off+s.n:s.off+s.n])
		}
	}
	return nil
}

// Cancel asks the server, on a connection of its own, to cancel what this session is running.
// It may be called from another goroutine.
func (c *Conn) Cancel(ctx context.Context) error {
	nc, err := dial(&c.cfg, ctx)
	if err != nil {
		return err
	}
	defer nc.Close()
	nc.SetDeadline(time.Now().Add(3 * time.Second))
	_, err = nc.Write(cancelPacket(c.pid, c.key))
	if err == nil { // the server closes it when done; wait for that (bounded)
		var b [1]byte
		nc.Read(b[:])
	}
	return err
}

func cancelPacket(pid, key uint32) []byte {
	b := make([]byte, 16)
	binary.BigEndian.PutUint32(b, 16)
	binary.BigEndian.PutUint32(b[4:], 80877102)
	binary.BigEndian.PutUint32(b[8:], pid)
	binary.BigEndian.PutUint32(b[12:], key)
	return b
}

// Kill closes the socket under a running Exec (from another goroutine): the Exec returns an
// error and the connection is dropped.
func (c *Conn) Kill() { c.nc.Close() }

// Close says Terminate and closes.
func (c *Conn) Close() error {
	c.nc.SetWriteDeadline(time.Now().Add(time.Second))
	c.nc.Write([]byte{'X', 0, 0, 0, 4})
	return c.nc.Close()
}
