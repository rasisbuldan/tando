// Package sdbus asks systemd for unit properties over its private D-Bus socket
// (/run/systemd/private, root only, peer to peer: no bus daemon, no Hello). UnitProps lists the
// loaded units (one call that loads nothing) and writes the property Gets of all of them at once;
// a unit that is not loaded is not asked what systemd would only learn by loading it. `systemctl
// show` of N units costs about 0.6 ms of its own CPU per unit, and systemd one load per unit it
// has not loaded; this costs a fraction of both.
//
// Only what that needs of the D-Bus wire format is here: little-endian method calls with string
// arguments, replies whose body is one variant of a basic type, and ListUnitsByPatterns' array.
//
// Layer: internal: the standard library only (status and daemon use it); never a domain package or
// daemon.
package sdbus

import (
	"bufio"
	"fmt"
	"io"
	"strconv"
	"strings"
	"time"
)

// Socket is systemd's private bus socket.
const Socket = "/run/systemd/private"

// Prop is a property to read: its D-Bus interface (org.freedesktop.systemd1.Unit, ...Service)
// and name.
type Prop struct{ Iface, Name string }

// Conn is an authenticated connection.
type Conn struct {
	rw     io.ReadWriteCloser
	r      *bufio.Reader
	dl     func(time.Time) error
	serial uint32
}

// NewConn authenticates as uid (EXTERNAL) on rw, a connected stream (tests pass one end of a
// pipe). setDeadline may be nil.
func NewConn(rw io.ReadWriteCloser, uid int, setDeadline func(time.Time) error) (*Conn, error) {
	c := &Conn{rw: rw, r: bufio.NewReaderSize(rw, 64<<10), dl: setDeadline}
	if err := c.auth(uid); err != nil {
		rw.Close()
		return nil, fmt.Errorf("auth: %w", err)
	}
	return c, nil
}

// Close closes the connection.
func (c *Conn) Close() error { return c.rw.Close() }

// SetDeadline bounds the rest of the conversation (nothing when the stream has no deadlines).
func (c *Conn) SetDeadline(t time.Time) error {
	if c.dl == nil {
		return nil
	}
	return c.dl(t)
}

func (c *Conn) auth(uid int) error {
	hex := fmt.Sprintf("%x", strconv.Itoa(uid))
	if _, err := io.WriteString(c.rw, "\x00AUTH EXTERNAL "+hex+"\r\n"); err != nil {
		return err
	}
	l, err := c.r.ReadString('\n')
	if err != nil {
		return err
	}
	if !strings.HasPrefix(l, "OK ") {
		return fmt.Errorf("refused: %q", strings.TrimSpace(l))
	}
	// BEGIN, and with it a Ping that wants no answer: systemd (seen with 259) leaves the first
	// message after the handshake unanswered until more bytes arrive on the connection, so the
	// first real call must not be the first message
	c.serial++
	ping := appendMethod([]byte("BEGIN\r\n"), c.serial, "/", "org.freedesktop.DBus.Peer", "Ping")
	ping[len("BEGIN\r\n")+2] |= flagNoReply
	_, err = c.rw.Write(ping)
	return err
}

// UnitPath is the object path of a unit: /org/freedesktop/systemd1/unit/ and the name with every
// byte but [A-Za-z0-9] written as _xx (and a leading digit too), as systemd's bus_label_escape.
func UnitPath(unit string) string {
	var b strings.Builder
	b.WriteString("/org/freedesktop/systemd1/unit/")
	if unit == "" {
		b.WriteByte('_')
	}
	for i := 0; i < len(unit); i++ {
		ch := unit[i]
		if (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9' && i > 0) {
			b.WriteByte(ch)
			continue
		}
		fmt.Fprintf(&b, "_%02x", ch)
	}
	return b.String()
}

// Get reads props of every unit: one map per unit, in the order of units, each value as
// `systemctl show` prints it (a number in decimal, a string as it is; "infinity" for the largest
// uint64 of a limit and "[not set]" for one of a counter cannot be told apart here, so both are
// "": callers treat anything that is not a number as not there). A unit systemd does not know
// is loaded on demand and reads as inactive, as with systemctl.
func (c *Conn) Get(units []string, props []Prop) ([]map[string]string, error) {
	var w []byte
	type want struct{ unit, prop int }
	pending := map[uint32]want{}
	for ui, u := range units {
		p := UnitPath(u)
		for pi, pr := range props {
			c.serial++
			w = appendCall(w, c.serial, p, pr.Iface, pr.Name)
			pending[c.serial] = want{ui, pi}
		}
	}
	res := make([]map[string]string, len(units))
	for i := range res {
		res[i] = make(map[string]string, len(props))
	}
	if len(w) == 0 {
		return res, nil
	}
	if _, err := c.rw.Write(w); err != nil {
		return nil, err
	}
	for len(pending) > 0 {
		m, err := readMsg(c.r)
		if err != nil {
			return nil, err
		}
		wnt, ok := pending[m.replySerial]
		if !ok || (m.typ != typeReturn && m.typ != typeError) {
			continue // a signal, or an answer to something else
		}
		delete(pending, m.replySerial)
		if m.typ == typeError {
			return nil, fmt.Errorf("%s %s: %s", units[wnt.unit], props[wnt.prop].Name, m.errName)
		}
		v, err := variant(m.body, m.sig)
		if err != nil {
			return nil, fmt.Errorf("%s %s: %w", units[wnt.unit], props[wnt.prop].Name, err)
		}
		res[wnt.unit][props[wnt.prop].Name] = v
	}
	return res, nil
}

// UnitProps reads props of the service units the way that costs systemd least. Asking about a
// unit loads it, and a unit that is not loaded but has a unit file (a stopped app) is parsed,
// announced to every client and garbage-collected again for every question: about 3 ms of
// systemd's CPU each time, where a loaded unit's property costs next to nothing. So the loaded
// units are listed first (one call that loads nothing; units are tando-<app>... names, the
// pattern "tando-*") and asked everything; for the others the state of a unit just loaded is
// known (inactive, no restarts, no CPU time, never entered: what `systemctl show` would print
// after loading it), what comes from their unit file is taken from fromFile when it can say
// (nil: never), and only the rest is asked, in one message per property.
func (c *Conn) UnitProps(units []string, props []Prop, fromFile func(unit, prop string) (string, bool)) ([]map[string]string, error) {
	loaded, err := c.Loaded("tando-*")
	if err != nil {
		return nil, err
	}
	var in, ask []string
	var inIdx, askIdx []int
	res := make([]map[string]string, len(units))
	var fileProps []Prop
	for _, p := range props {
		if _, ok := fresh(p.Name); !ok {
			fileProps = append(fileProps, p)
		}
	}
	for i, u := range units {
		if _, ok := loaded[u]; ok {
			in, inIdx = append(in, u), append(inIdx, i)
			continue
		}
		m := map[string]string{}
		for _, p := range props {
			if v, ok := fresh(p.Name); ok {
				m[p.Name] = v
			}
		}
		res[i] = m
		known := fromFile != nil
		for _, p := range fileProps {
			if !known {
				break
			}
			var v string
			if v, known = fromFile(u, p.Name); known {
				m[p.Name] = v
			}
		}
		if !known {
			ask, askIdx = append(ask, u), append(askIdx, i)
		}
	}
	got, err := c.Get(in, props)
	if err != nil {
		return nil, err
	}
	for k, i := range inIdx {
		res[i] = got[k]
	}
	got, err = c.Get(ask, fileProps)
	if err != nil {
		return nil, err
	}
	for k, i := range askIdx {
		for name, v := range got[k] {
			res[i][name] = v
		}
	}
	return res, nil
}

// fresh is a property of a unit just loaded, which nothing has started since ("": not set).
func fresh(name string) (string, bool) {
	switch name {
	case "ActiveState":
		return "inactive", true
	case "NRestarts", "ActiveEnterTimestampMonotonic":
		return "0", true
	case "CPUUsageNSec":
		return "", true
	}
	return "", false
}

// Loaded lists the units systemd has loaded whose names match pattern (fnmatch), with their
// ActiveState: Manager.ListUnitsByPatterns, which loads nothing. A unit that is not loaded is
// inactive and unknown to systemd until something asks for it (asking loads it, and for a unit
// with a unit file that costs systemd a parse and a garbage collection each time).
func (c *Conn) Loaded(pattern string) (map[string]string, error) {
	c.serial++
	serial := c.serial
	w := appendListByPatterns(nil, serial, pattern)
	if _, err := c.rw.Write(w); err != nil {
		return nil, err
	}
	for {
		m, err := readMsg(c.r)
		if err != nil {
			return nil, err
		}
		if m.replySerial != serial || (m.typ != typeReturn && m.typ != typeError) {
			continue
		}
		if m.typ == typeError {
			return nil, fmt.Errorf("ListUnitsByPatterns: %s", m.errName)
		}
		if m.sig != "a(ssssssouso)" {
			return nil, fmt.Errorf("ListUnitsByPatterns: reply of signature %q", m.sig)
		}
		return parseUnitList(m.body)
	}
}
