package sdbus

import (
	"bufio"
	"bytes"
	"io"
	"testing"
)

// replay is a connection whose reads come from a fixed byte string (what "systemd" answers) and
// whose writes are dropped.
type replay struct{ r io.Reader }

func (p replay) Read(b []byte) (int, error)  { return p.r.Read(b) }
func (p replay) Write(b []byte) (int, error) { return len(b), nil }
func (p replay) Close() error                { return nil }

func replayConn(data []byte) *Conn {
	rw := replay{bytes.NewReader(data)}
	return &Conn{rw: rw, r: bufio.NewReaderSize(rw, 64<<10)}
}

// FuzzReplies: whatever comes back on the socket, the reply parsing (message header, header
// fields, a variant body, the unit list) returns an error or values, never panics and never
// waits for more than the bytes there are. Replies come from systemd (root), so this is about
// robustness: a damaged or unexpected message must not take a status call or tandod down.
func FuzzReplies(f *testing.F) {
	var seed []byte
	seed = appendUnitList(seed, 1, 1, map[string]any{"tando-a.service": "active", "tando-b.service": "failed"})
	seed = appendReturn(seed, 2, 2, "s", "active")
	seed = appendReturn(seed, 3, 3, "t", uint64(12345))
	seed = appendReturn(seed, 4, 4, "u", uint32(7))
	seed = appendError(seed, 5, 5, "org.freedesktop.DBus.Error.UnknownObject")
	f.Add(seed)
	f.Add(appendReturn(nil, 1, 1, "b", uint32(1)))
	f.Add(appendReturn(nil, 1, 1, "x", uint64(1<<63)))
	f.Add(appendReturn(nil, 1, 1, "o", "/org/freedesktop/systemd1/unit/x"))
	f.Add(appendError(nil, 9, 1, "x"))
	f.Add(appendUnitList(nil, 1, 1, nil))
	f.Add([]byte("l\x02\x00\x01\xff\xff\xff\xff\x01\x00\x00\x00\xff\xff\xff\xff"))
	f.Add([]byte("B\x02\x00\x01"))
	f.Fuzz(func(t *testing.T, data []byte) {
		// the messages one by one, each body read every way a reply is read
		r := bufio.NewReader(bytes.NewReader(data))
		for range 64 {
			m, err := readMsg(r)
			if err != nil {
				break
			}
			variant(m.body, m.sig)
			variant(m.body, "v")
			parseUnitList(m.body)
		}
		// the calls on a connection that answers with data
		props := []Prop{{"org.freedesktop.systemd1.Unit", "ActiveState"}, {"org.freedesktop.systemd1.Service", "NRestarts"}}
		replayConn(data).Get([]string{"tando-a.service", "tando-b.service"}, props)
		replayConn(data).Loaded("tando-*")
		replayConn(data).UnitProps([]string{"tando-a.service", "tando-c.service"}, props, nil)
	})
}
