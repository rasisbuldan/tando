package pgwire

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"strings"
	"testing"
	"time"
)

// ---- a scripted PostgreSQL on the other end of a net.Pipe ----------------------------------

type fake struct {
	t   *testing.T
	nc  net.Conn
	r   *bufio.Reader
	got []string // the frontend messages: type letter + body
}

func msgB(t byte, parts ...[]byte) []byte {
	var body []byte
	for _, p := range parts {
		body = append(body, p...)
	}
	b := []byte{t, 0, 0, 0, 0}
	binary.BigEndian.PutUint32(b[1:], uint32(len(body)+4))
	return append(b, body...)
}
func u32(v uint32) []byte  { return binary.BigEndian.AppendUint32(nil, v) }
func u16(v uint16) []byte  { return binary.BigEndian.AppendUint16(nil, v) }
func cstr(s string) []byte { return append([]byte(s), 0) }

func authOK() []byte          { return msgB('R', u32(0)) }
func ready(s byte) []byte     { return msgB('Z', []byte{s}) }
func cmdDone(t string) []byte { return msgB('C', cstr(t)) }
func rowDescB(names ...string) []byte {
	b := u16(uint16(len(names)))
	for _, n := range names {
		b = append(b, cstr(n)...)
		b = append(b, u32(0)...)
		b = append(b, u16(0)...)
		b = append(b, u32(25)...)
		b = append(b, u16(0xffff)...)
		b = append(b, u32(0xffffffff)...)
		b = append(b, u16(0)...)
	}
	return msgB('T', b)
}
func dataRowB(cells ...*string) []byte {
	b := u16(uint16(len(cells)))
	for _, c := range cells {
		if c == nil {
			b = append(b, u32(0xffffffff)...)
		} else {
			b = append(b, u32(uint32(len(*c)))...)
			b = append(b, *c...)
		}
	}
	return msgB('D', b)
}
func sp(s string) *string { return &s }
func errB(code, msg, pos string) []byte {
	b := append([]byte{'S'}, cstr("ERROR")...)
	b = append(append(b, 'C'), cstr(code)...)
	b = append(append(b, 'M'), cstr(msg)...)
	b = append(append(b, 'D'), cstr("the detail")...)
	b = append(append(b, 'H'), cstr("the hint")...)
	if pos != "" {
		b = append(append(b, 'P'), cstr(pos)...)
	}
	return msgB('E', append(b, 0))
}

// startup reads the startup packet and returns its parameters
func (f *fake) startup() map[string]string {
	var h [8]byte
	if _, err := io.ReadFull(f.r, h[:]); err != nil {
		f.t.Errorf("startup: %v", err)
		return nil
	}
	n := binary.BigEndian.Uint32(h[:])
	if binary.BigEndian.Uint32(h[4:]) != 196608 {
		f.t.Errorf("protocol %x", h[4:])
	}
	body := make([]byte, n-8)
	io.ReadFull(f.r, body)
	p := map[string]string{}
	parts := strings.Split(strings.TrimRight(string(body), "\x00"), "\x00")
	for i := 0; i+1 < len(parts); i += 2 {
		p[parts[i]] = parts[i+1]
	}
	return p
}

// next reads one frontend message
func (f *fake) next() (byte, []byte) {
	var h [5]byte
	if _, err := io.ReadFull(f.r, h[:]); err != nil {
		return 0, nil
	}
	b := make([]byte, binary.BigEndian.Uint32(h[1:])-4)
	io.ReadFull(f.r, b)
	f.got = append(f.got, string(h[0])+string(b))
	return h[0], b
}
func (f *fake) send(bs ...[]byte) {
	for _, b := range bs {
		if _, err := f.nc.Write(b); err != nil {
			return
		}
	}
}

// pair: a client config dialing a fake whose script runs in a goroutine
func pair(t *testing.T, script func(f *fake)) (Config, chan struct{}) {
	done := make(chan struct{})
	cfg := Config{Addr: "fake", User: "u", Database: "d", Password: "pencil", scramUser: "user",
		nonce: "rOprNGfwEbeRWgbNEkqO"}
	cfg.Dial = func(context.Context, string) (net.Conn, error) {
		a, b := net.Pipe()
		go func() {
			defer close(done)
			defer b.Close()
			script(&fake{t: t, nc: b, r: bufio.NewReader(b)})
		}()
		return a, nil
	}
	return cfg, done
}

// login: the RFC 7677 exchange, checked message by message
func (f *fake) login() {
	f.startup()
	f.send(msgB('R', u32(10), cstr("SCRAM-SHA-256-PLUS"), cstr("SCRAM-SHA-256"), []byte{0}))
	_, b := f.next()
	want := "SCRAM-SHA-256\x00" + string(u32(32)) + "n,,n=user,r=rOprNGfwEbeRWgbNEkqO"
	if string(b) != want {
		f.t.Errorf("client-first %q", b)
	}
	f.send(msgB('R', u32(11), []byte("r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096")))
	_, b = f.next()
	if string(b) != "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=" {
		f.t.Errorf("client-final %q", b)
	}
	f.send(msgB('R', u32(12), []byte("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=")), authOK(),
		msgB('S', cstr("server_version"), cstr("16.4")), msgB('S', cstr("standard_conforming_strings"), cstr("on")),
		msgB('K', u32(4242), u32(0xdeadbeef)), ready('I'))
}

func connect(t *testing.T, cfg Config) *Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, err := Connect(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	return c
}

// ---- login ----------------------------------------------------------------------------------

func TestScramRFC7677(t *testing.T) {
	var params map[string]string
	cfg, done := pair(t, func(f *fake) {
		f.login()
		f.next() // Terminate
	})
	cfg.Params = [][2]string{{"application_name", "x"}, {"default_transaction_read_only", "on"}}
	_ = params
	c := connect(t, cfg)
	if c.Param("server_version") != "16.4" || c.pid != 4242 || c.key != 0xdeadbeef || c.TxStatus() != 'I' {
		t.Fatalf("%v %d %x %c", c.params, c.pid, c.key, c.tx)
	}
	c.Close()
	<-done
}

func TestStartupParams(t *testing.T) {
	cfg, done := pair(t, func(f *fake) {
		p := f.startup()
		if p["user"] != "u" || p["database"] != "d" || p["default_transaction_read_only"] != "on" || p["statement_timeout"] != "30s" {
			t.Errorf("startup params %v", p)
		}
		f.send(errB("53300", "too many connections for role \"u\"", ""))
	})
	cfg.Params = [][2]string{{"default_transaction_read_only", "on"}, {"statement_timeout", "30s"}}
	_, err := Connect(context.Background(), cfg)
	var e *Error
	if !errors.As(err, &e) || e.Code != "53300" {
		t.Fatalf("got %v", err)
	}
	<-done
	cfg.Params = [][2]string{{"x", "a\x00b"}}
	if _, err := Connect(context.Background(), cfg); err == nil {
		t.Fatal("a NUL in a parameter must be refused")
	}
}

func TestLoginRefusals(t *testing.T) {
	cases := []struct {
		name   string
		answer []byte
		want   string
	}{
		{"md5", msgB('R', u32(5), []byte{1, 2, 3, 4}), "not a SCRAM verifier"},
		{"cleartext", msgB('R', u32(3)), "not a SCRAM verifier"},
		{"gss", msgB('R', u32(7)), "does not support (7)"},
		{"plus only", msgB('R', u32(10), cstr("SCRAM-SHA-256-PLUS"), []byte{0}), "no SCRAM-SHA-256"},
		{"trust", append(authOK(), ready('I')...), "without a password"},
		{"negotiate", msgB('v', u32(0), u32(0)), "another protocol version"},
		{"ok before scram", msgB('R', u32(0)), ""},
		{"garbage", []byte("HTTP/1.1 400 Bad\r\n\r\n"), "protocol"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfg, done := pair(t, func(f *fake) {
				f.startup()
				f.send(tc.answer)
				if tc.name == "ok before scram" {
					f.send(ready('I'))
				}
			})
			_, err := Connect(context.Background(), cfg)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("got %v, want %q", err, tc.want)
			}
			<-done
		})
	}
}

func TestScramBadServerSignatureAndNonce(t *testing.T) {
	for _, tc := range []struct{ first, final, want string }{
		{"r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096", "v=AAAA", "signature"},
		{"r=someoneelse,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096", "", "nonce"},
		{"r=rOprNGfwEbeRWgbNEkqOx,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=99999999", "", "iteration"},
		{"r=rOprNGfwEbeRWgbNEkqOx,s=,i=4096", "", "salt"},
	} {
		cfg, done := pair(t, func(f *fake) {
			f.startup()
			f.send(msgB('R', u32(10), cstr("SCRAM-SHA-256"), []byte{0}))
			f.next()
			f.send(msgB('R', u32(11), []byte(tc.first)))
			if tc.final != "" {
				f.next()
				f.send(msgB('R', u32(12), []byte(tc.final)), authOK(), ready('I'))
			}
		})
		_, err := Connect(context.Background(), cfg)
		if err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: got %v", tc.want, err)
		}
		<-done
	}
}

// ---- statements -----------------------------------------------------------------------------

func TestExecMessagesAndResult(t *testing.T) {
	cfg, done := pair(t, func(f *fake) {
		f.login()
		for i := 0; i < 5; i++ { // P B D E S
			f.next()
		}
		f.send(msgB('1'), msgB('2'), rowDescB("a", "b"), dataRowB(sp("1"), nil),
			msgB('N', []byte("SNOTICE\x00Mmid-stream\x00\x00")), msgB('S', cstr("TimeZone"), cstr("UTC")),
			dataRowB(sp(""), sp("x")), cmdDone("SELECT 2"), ready('T'))
		f.next()
	})
	c := connect(t, cfg)
	s := &rec{}
	r, err := c.Exec("SELECT $1, $2", [][]byte{[]byte("v"), nil}, 11, 100, 1000, s)
	if err != nil || r.Err != nil || r.Tag != "SELECT 2" || len(s.rows) != 2 || s.rows[0][1] != "\x00NULL" || s.rows[1][0] != "" {
		t.Fatalf("%v %+v %q", err, r, s.rows)
	}
	if len(r.Notices) != 1 || r.Notices[0].Message != "mid-stream" || c.Param("TimeZone") != "UTC" || c.TxStatus() != 'T' {
		t.Fatalf("%+v", r)
	}
	c.Close()
	<-done
}

func TestExecWireBytes(t *testing.T) {
	var got []string
	cfg, done := pair(t, func(f *fake) {
		f.login()
		for i := 0; i < 5; i++ {
			f.next()
		}
		got = f.got[2:]
		f.send(msgB('1'), msgB('2'), msgB('n'), cmdDone("SET"), ready('T'))
	})
	c := connect(t, cfg)
	if _, err := c.Exec("SET x = $1", [][]byte{nil, []byte("ab")}, 1001, 10, 10, &rec{}); err != nil {
		t.Fatal(err)
	}
	<-done
	want := []string{
		"P\x00SET x = $1\x00\x00\x00",
		"B\x00\x00\x00\x00\x00\x02\xff\xff\xff\xff\x00\x00\x00\x02ab\x00\x00",
		"DP\x00",
		"E\x00\x00\x00\x03\xe9",
		"S",
	}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("got  %q\nwant %q", got, want)
	}
}

func TestErrorFields(t *testing.T) {
	cfg, done := pair(t, func(f *fake) {
		f.login()
		for i := 0; i < 5; i++ {
			f.next()
		}
		f.send(errB("42P01", "relation \"nope\" does not exist", "15"), ready('E'))
	})
	c := connect(t, cfg)
	r, err := c.Exec("SELECT * FROM nope", nil, 0, 10, 10, &rec{})
	if err != nil || r.Err == nil || r.Err.Code != "42P01" || r.Err.Position != 15 || r.Err.Detail != "the detail" || r.Err.Hint != "the hint" || c.TxStatus() != 'E' {
		t.Fatalf("%v %+v", err, r.Err)
	}
	<-done
}

// A cell over the cap is cut and the rest discarded exactly: the next message still parses.
func TestDataRowCutKeepsTheStreamInSync(t *testing.T) {
	big := strings.Repeat("x", 300000)
	cfg, done := pair(t, func(f *fake) {
		f.login()
		for i := 0; i < 5; i++ {
			f.next()
		}
		f.send(msgB('1'), msgB('2'), rowDescB("a", "b", "c"), dataRowB(sp(big), sp("tail"), nil),
			dataRowB(sp("abc"), sp(big), sp(big)), cmdDone("SELECT 2"), ready('T'))
	})
	c := connect(t, cfg)
	s := &rec{}
	r, err := c.Exec("x", nil, 0, 1000, 1500, s)
	if err != nil || r.Err != nil || r.Tag != "SELECT 2" {
		t.Fatal(err, r)
	}
	if len(s.rows[0][0]) != 1000 || s.full[0][0] != 300000 || s.rows[0][1] != "tail" || s.full[0][1] != -1 || s.rows[0][2] != "\x00NULL" {
		t.Fatalf("row 0: %d %v", len(s.rows[0][0]), s.full[0])
	}
	// row cap 1500: abc (3) + 1000 + 497
	if s.rows[1][0] != "abc" || len(s.rows[1][1]) != 1000 || len(s.rows[1][2]) != 497 || s.full[1][2] != 300000 {
		t.Fatalf("row 1: %d %d %v", len(s.rows[1][1]), len(s.rows[1][2]), s.full[1])
	}
	<-done
}

func TestPortalSuspendedAndStop(t *testing.T) {
	cfg, done := pair(t, func(f *fake) {
		f.login()
		for i := 0; i < 5; i++ {
			f.next()
		}
		f.send(msgB('1'), msgB('2'), rowDescB("a"))
		for i := 0; i < 5; i++ {
			f.send(dataRowB(sp("r")))
		}
		f.send(msgB('s'), ready('T'))
	})
	c := connect(t, cfg)
	s := &rec{stop: 2}
	r, err := c.Exec("x", nil, 5, 10, 10, s)
	if err != nil || !r.Suspended || !r.Stopped || len(s.rows) != 2 || c.TxStatus() != 'T' {
		t.Fatalf("%v %+v %d", err, r, len(s.rows))
	}
	<-done
}

func TestCopyInAnsweredWithCopyFailAndSync(t *testing.T) {
	cfg, done := pair(t, func(f *fake) {
		f.login()
		for i := 0; i < 5; i++ {
			f.next()
		}
		f.send(msgB('1'), msgB('2'), msgB('n'), msgB('G', []byte{0}, u16(0)))
		if t1, _ := f.next(); t1 != 'f' {
			t.Errorf("want CopyFail, got %q", t1)
		}
		if t2, _ := f.next(); t2 != 'S' {
			t.Errorf("want Sync after CopyFail, got %q", t2)
		}
		f.send(errB("57014", "COPY from stdin failed", ""), ready('T'))
	})
	c := connect(t, cfg)
	r, err := c.Exec("COPY t FROM STDIN", nil, 0, 10, 10, &rec{})
	if err != nil || r.Err == nil || !r.Copy {
		t.Fatalf("%v %+v", err, r)
	}
	<-done
}

func TestCopyOutDrained(t *testing.T) {
	cfg, done := pair(t, func(f *fake) {
		f.login()
		for i := 0; i < 5; i++ {
			f.next()
		}
		f.send(msgB('1'), msgB('2'), msgB('n'), msgB('H', []byte{0}, u16(0)),
			msgB('d', []byte("1\n")), msgB('d', []byte("2\n")), msgB('c'), cmdDone("COPY 2"), ready('T'))
	})
	c := connect(t, cfg)
	r, err := c.Exec("COPY t TO STDOUT", nil, 0, 10, 10, &rec{})
	if err != nil || r.Err == nil || !strings.Contains(r.Err.Message, "tando db psql") || c.TxStatus() != 'T' {
		t.Fatalf("%v %+v", err, r)
	}
	<-done
}

func TestCancelPacketBytes(t *testing.T) {
	want := []byte{0, 0, 0, 16, 0x04, 0xd2, 0x16, 0x2e, 0, 0, 0x10, 0x92, 0xde, 0xad, 0xbe, 0xef}
	if got := cancelPacket(4242, 0xdeadbeef); !bytes.Equal(got, want) {
		t.Fatalf("%x", got)
	}
	got := make(chan []byte, 1)
	cfg := Config{Addr: "x", Dial: func(context.Context, string) (net.Conn, error) {
		a, b := net.Pipe()
		go func() {
			buf := make([]byte, 16)
			io.ReadFull(b, buf)
			got <- buf
			b.Close()
		}()
		return a, nil
	}}
	c := &Conn{cfg: cfg, pid: 4242, key: 0xdeadbeef}
	if err := c.Cancel(context.Background()); err != nil {
		t.Fatal(err)
	}
	if b := <-got; !bytes.Equal(b, want) {
		t.Fatalf("on the wire %x", b)
	}
}

func TestShortReadAndOversize(t *testing.T) {
	cfg, done := pair(t, func(f *fake) {
		f.login()
		f.next()
		f.send([]byte{'T', 0, 0, 1}) // a header cut short, then close
	})
	c := connect(t, cfg)
	if _, err := c.Exec("x", nil, 0, 1, 1, &rec{}); err == nil {
		t.Fatal("a short read must fail")
	}
	<-done
	cfg, done = pair(t, func(f *fake) {
		f.login()
		f.next()
		f.send([]byte{'T', 0x7f, 0, 0, 0})
	})
	c = connect(t, cfg)
	_, err := c.Exec("x", nil, 0, 1, 1, &rec{})
	var pe *ProtocolError
	if !errors.As(err, &pe) {
		t.Fatalf("an oversized message: %v", err)
	}
	<-done
}

// ---- fuzz -----------------------------------------------------------------------------------

// rwConn reads a fixed byte stream and discards writes
type rwConn struct {
	net.Conn
	r io.Reader
}

func (c rwConn) Read(b []byte) (int, error)        { return c.r.Read(b) }
func (c rwConn) Write(b []byte) (int, error)       { return len(b), nil }
func (c rwConn) Close() error                      { return nil }
func (c rwConn) SetDeadline(time.Time) error       { return nil }
func (c rwConn) SetWriteDeadline(time.Time) error  { return nil }
func (c rwConn) SetReadDeadline(t time.Time) error { return nil }

func fuzzConn(b []byte) *Conn {
	rc := rwConn{r: bytes.NewReader(b)}
	return &Conn{nc: rc, r: bufio.NewReader(rc), params: map[string]string{}}
}

// FuzzReadMessage: whatever a server sends, Exec, Simple and the login return; never panic,
// never keep more than the caps.
func FuzzReadMessage(f *testing.F) {
	f.Add(append(append(append(msgB('1'), msgB('2')...), rowDescB("a")...), append(dataRowB(sp("x"), nil), append(cmdDone("SELECT 1"), ready('T')...)...)...))
	f.Add(append(errB("42P01", "x", "3"), ready('E')...))
	f.Add(append(msgB('G', []byte{0}, u16(0)), ready('T')...))
	f.Add(append(msgB('H', []byte{0}, u16(0)), append(msgB('d', []byte("x")), append(msgB('c'), ready('I')...)...)...))
	f.Add(append(msgB('R', u32(10), cstr("SCRAM-SHA-256"), []byte{0}), msgB('R', u32(11), []byte("r=abcx,s=AAAA,i=1"))...))
	f.Fuzz(func(t *testing.T, b []byte) {
		s := &capRec{t: t}
		c := fuzzConn(b)
		c.Exec("x", nil, 3, 7, 20, s)
		fuzzConn(b).Simple("x")
		c = fuzzConn(b)
		c.cfg = Config{Password: "p", nonce: "abc"}
		c.startup()
	})
}

// FuzzDataRow: the stream reader of one DataRow; cells within the caps, never a panic
func FuzzDataRow(f *testing.F) {
	f.Add(dataRowB(sp("abc"), nil, sp(strings.Repeat("y", 40)))[5:], 5, 10)
	f.Add([]byte{0, 1, 0xff, 0xff, 0xff, 0xfe}, 3, 3)
	f.Fuzz(func(t *testing.T, b []byte, cellCap, rowCap int) {
		cellCap, rowCap = cellCap&0xffff, rowCap&0xffff
		c := fuzzConn(b)
		var cells [][]byte
		var full []int
		if err := c.dataRow(len(b), cellCap, rowCap, &cells, &full); err != nil {
			return
		}
		tot := 0
		for i, x := range cells {
			if len(x) > cellCap || full[i] != -1 && full[i] <= len(x) {
				t.Fatalf("cell %d: %d bytes, full %d, cap %d", i, len(x), full[i], cellCap)
			}
			tot += len(x)
		}
		if tot > rowCap {
			t.Fatalf("row of %d bytes, cap %d", tot, rowCap)
		}
	})
}

type capRec struct{ t *testing.T }

func (r *capRec) Columns([]Field) error { return nil }
func (r *capRec) Row(c [][]byte, _ []int) error {
	n := 0
	for _, x := range c {
		if len(x) > 7 {
			r.t.Fatalf("cell of %d bytes over the cap", len(x))
		}
		n += len(x)
	}
	if n > 20 {
		r.t.Fatalf("row of %d bytes over the cap", n)
	}
	return nil
}
