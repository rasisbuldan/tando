package daemon

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"os"
	"sync"
	"time"

	"tando/srv/daemon/proto"
)

// Limits of the socket: a client may hold one of maxConns slots, has readTimeout to send its
// request line, and a verb gets verbTimeout (a tick tickTimeout) and at most maxAnswer bytes.
const (
	maxConns     = 8
	readTimeout  = 2 * time.Second
	writeTimeout = 10 * time.Second
	verbTimeout  = 30 * time.Second
	maxAnswer    = 8 << 20
)

var errBusy = errors.New("busy")

// refuseBusy answers "busy" to a client over the connection cap, after reading its request line
// (at most MaxRequest bytes, 1 s): closing before the client has written would give it EPIPE on
// Linux instead of the answer.
func refuseBusy(c net.Conn) {
	defer c.Close()
	c.SetDeadline(time.Now().Add(time.Second))
	bufio.NewReaderSize(io.LimitReader(c, proto.MaxRequest), proto.MaxRequest).ReadString('\n')
	io.WriteString(c, proto.Header(errBusy, 0))
}

// handler answers one checked request, writing the rows of its verb to w.
type handler func(ctx context.Context, r proto.Request, w io.Writer) error

// server serves the socket.
type server struct {
	ln      net.Listener
	handle  handler
	peerUID func(net.Conn) (int, error) // SO_PEERCRED; tests replace it
	slots   chan struct{}
	wg      sync.WaitGroup
}

// listen makes the socket: a stale one (a daemon killed hard) is replaced; it is 0600 before
// anyone can connect (umask), in the 0700 directory systemd makes (RuntimeDirectory=tando).
func listen(path string) (net.Listener, error) {
	if fi, err := os.Lstat(path); err == nil && fi.Mode()&os.ModeSocket != 0 {
		os.Remove(path)
	}
	old := umask(0o177)
	ln, err := net.Listen("unix", path)
	umask(old)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(path, 0o600); err != nil {
		ln.Close()
		return nil, err
	}
	return ln, nil
}

func newServer(ln net.Listener, h handler) *server {
	return &server{ln: ln, handle: h, peerUID: peerUID, slots: make(chan struct{}, maxConns)}
}

// serve accepts until the listener is closed; then it waits for the connections being served.
func (s *server) serve(ctx context.Context) {
	for {
		c, err := s.ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				break
			}
			time.Sleep(100 * time.Millisecond) // (a full file table: try again later, no spin)
			continue
		}
		select {
		case s.slots <- struct{}{}:
		default:
			go refuseBusy(c) // (not in the accept loop: its client may be slow)
			continue
		}
		s.wg.Add(1)
		go func() {
			defer s.wg.Done()
			defer func() { <-s.slots }()
			s.conn(ctx, c)
		}()
	}
	s.wg.Wait()
}

// conn serves one client: root only, one line, one verb.
func (s *server) conn(ctx context.Context, c net.Conn) {
	defer c.Close()
	if uid, err := s.peerUID(c); err != nil || uid != 0 {
		return // closed without a word: the client falls back to running the verb itself
	}
	c.SetReadDeadline(time.Now().Add(readTimeout))
	line, err := bufio.NewReaderSize(io.LimitReader(c, proto.MaxRequest), proto.MaxRequest).ReadString('\n')
	if err != nil {
		writeAnswer(c, errors.New("bad request"), nil)
		return
	}
	r, err := proto.Parse(line[:len(line)-1])
	if err != nil {
		writeAnswer(c, err, nil)
		return
	}
	timeout := verbTimeout
	if r.Verb == "tick" {
		timeout = tickTimeout + 10*time.Second
	}
	vctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	var b capped
	var p any
	var stack []byte
	err, p, stack = guard(func() error { return s.handle(vctx, r, &b) })
	if p != nil { // (a panic in a verb ends this request, not the daemon)
		journalErr("tandod: %s panicked: %v\n%s", r.Verb, p, stack)
		err, b.Buffer = errors.New("internal error"), bytes.Buffer{}
	}
	if errors.Is(err, errRefuse) {
		return // closed without an answer: the client does the work itself
	}
	if b.over {
		err, b.Buffer = errors.New("answer too long"), bytes.Buffer{}
	}
	writeAnswer(c, err, b.Bytes())
}

func writeAnswer(c net.Conn, err error, body []byte) {
	c.SetWriteDeadline(time.Now().Add(writeTimeout))
	io.WriteString(c, proto.Header(err, len(body)))
	c.Write(body)
}

// capped is a buffer that stops at maxAnswer.
type capped struct {
	bytes.Buffer
	over bool
}

func (b *capped) Write(p []byte) (int, error) {
	if b.Len()+len(p) > maxAnswer {
		b.over = true
		return 0, errors.New("answer too long")
	}
	return b.Buffer.Write(p)
}
