package sdbus

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math"
	"strconv"
	"strings"
)

// The D-Bus wire format, as much of it as this package needs: little-endian method calls with
// string arguments (appendMethod), the header fields of a reply (readMsg, parseFields), a reply
// body that is one variant of a basic type (variant) and ListUnitsByPatterns' array of structs
// (parseUnitList). Everything here but readMsg is pure: bytes in, values or an error out
// (FuzzReplies).

// flagNoReply is NO_REPLY_EXPECTED in a message header's flags.
const flagNoReply = 1

// appendListByPatterns appends Manager.ListUnitsByPatterns(states [], patterns [pattern]).
func appendListByPatterns(w []byte, serial uint32, pattern string) []byte {
	start := len(w)
	w = appendMethod(w, serial, "/org/freedesktop/systemd1", "org.freedesktop.systemd1.Manager", "ListUnitsByPatterns")
	// appendMethod wrote no signature and no body: add both (the signature field goes last in
	// the header, which then needs its length and padding redone)
	hdrEnd := start + 16 + int(binary.LittleEndian.Uint32(w[start+12:]))
	w = w[:hdrEnd]
	w = pad(w, start, 8)
	w = append(w, 8, 1, 'g', 0, 4, 'a', 's', 'a', 's', 0)
	binary.LittleEndian.PutUint32(w[start+12:], uint32(len(w)-start-16))
	w = pad(w, start, 8)
	body := len(w)
	w = binary.LittleEndian.AppendUint32(w, 0) // states: empty array of strings
	w = pad(w, start, 4)
	lenAt := len(w)
	w = binary.LittleEndian.AppendUint32(w, 0)
	elems := len(w)
	w = binary.LittleEndian.AppendUint32(w, uint32(len(pattern)))
	w = append(w, pattern...)
	w = append(w, 0)
	binary.LittleEndian.PutUint32(w[lenAt:], uint32(len(w)-elems))
	binary.LittleEndian.PutUint32(w[start+4:], uint32(len(w)-body))
	return w
}

// parseUnitList reads a(ssssssouso): name, description, load state, active state, sub state,
// following, path, job id, job type, job path; it keeps name -> active state.
func parseUnitList(b []byte) (map[string]string, error) {
	if len(b) < 4 {
		return nil, errors.New("short unit list")
	}
	n := int(binary.LittleEndian.Uint32(b))
	i := align(4, 8)
	end := i + n
	if n < 0 || end > len(b) {
		return nil, errors.New("short unit list")
	}
	res := map[string]string{}
	for i < end {
		i = align(i, 8)
		var f [10]string
		var err error
		for k := range f {
			switch k {
			case 7: // job id, u
				i = align(i, 4)
				if i+4 > len(b) {
					return nil, errors.New("short unit list")
				}
				i += 4
			default: // s or o
				if f[k], i, err = str(b, i); err != nil {
					return nil, err
				}
			}
		}
		res[f[0]] = f[3]
	}
	return res, nil
}

const (
	typeCall   = 1
	typeReturn = 2
	typeError  = 3
)

// appendCall appends a method call org.freedesktop.DBus.Properties.Get(iface, name) on path.
func appendCall(w []byte, serial uint32, path, iface, name string) []byte {
	return appendMethod(w, serial, path, "org.freedesktop.DBus.Properties", "Get", iface, name)
}

// appendMethod appends a method call iface.member(args...) on path, every argument a string.
func appendMethod(w []byte, serial uint32, path, iface, member string, args ...string) []byte {
	start := len(w)
	w = append(w, 'l', typeCall, 0, 1)
	w = binary.LittleEndian.AppendUint32(w, 0) // body length, set below
	w = binary.LittleEndian.AppendUint32(w, serial)
	w = binary.LittleEndian.AppendUint32(w, 0) // header fields array length, set below
	fields := len(w)
	field := func(code byte, sig byte, val string) {
		w = pad(w, start, 8)
		w = append(w, code, 1, sig, 0)
		if sig == 'g' {
			w = append(w, byte(len(val)))
		} else {
			w = pad(w, start, 4)
			w = binary.LittleEndian.AppendUint32(w, uint32(len(val)))
		}
		w = append(w, val...)
		w = append(w, 0)
	}
	field(1, 'o', path)
	field(6, 's', "org.freedesktop.systemd1")
	field(2, 's', iface)
	field(3, 's', member)
	if len(args) > 0 {
		field(8, 'g', strings.Repeat("s", len(args)))
	}
	binary.LittleEndian.PutUint32(w[fields-4:], uint32(len(w)-fields))
	w = pad(w, start, 8)
	body := len(w)
	for _, s := range args {
		w = pad(w, start, 4)
		w = binary.LittleEndian.AppendUint32(w, uint32(len(s)))
		w = append(w, s...)
		w = append(w, 0)
	}
	binary.LittleEndian.PutUint32(w[start+4:], uint32(len(w)-body))
	return w
}

func pad(w []byte, start, n int) []byte {
	for (len(w)-start)%n != 0 {
		w = append(w, 0)
	}
	return w
}

type msg struct {
	typ         byte
	serial      uint32
	path        string
	member      string
	replySerial uint32
	sig         string
	errName     string
	body        []byte
}

// maxMsg bounds one message (the D-Bus limit is 128 MiB; a property answer is tiny).
const maxMsg = 1 << 20

func readMsg(r *bufio.Reader) (msg, error) {
	var m msg
	head := make([]byte, 16)
	if _, err := io.ReadFull(r, head); err != nil {
		return m, err
	}
	if head[0] != 'l' {
		return m, errors.New("big-endian message")
	}
	m.typ = head[1]
	m.serial = binary.LittleEndian.Uint32(head[8:])
	bodyLen := binary.LittleEndian.Uint32(head[4:])
	fieldsLen := binary.LittleEndian.Uint32(head[12:])
	if bodyLen > maxMsg || fieldsLen > maxMsg {
		return m, errors.New("message too long")
	}
	fl := int(fieldsLen)
	padded := (16 + fl + 7) &^ 7
	rest := make([]byte, padded-16+int(bodyLen))
	if _, err := io.ReadFull(r, rest); err != nil {
		return m, err
	}
	all := append(head, rest...)
	if err := parseFields(all[:16+fl], &m); err != nil {
		return m, err
	}
	m.body = all[padded:]
	return m, nil
}

// parseFields reads the header fields that matter here (offsets relative to the message start).
func parseFields(b []byte, m *msg) error {
	i := 16
	for i < len(b) {
		i = align(i, 8)
		if i+4 > len(b) {
			break
		}
		code := b[i]
		sl := int(b[i+1])
		if i+2+sl+1 > len(b) {
			return errors.New("bad header field")
		}
		sig := string(b[i+2 : i+2+sl])
		i += 2 + sl + 1
		var err error
		var s string
		var u uint32
		switch sig {
		case "s", "o":
			s, i, err = str(b, i)
		case "g":
			s, i, err = sigStr(b, i)
		case "u":
			i = align(i, 4)
			if i+4 > len(b) {
				return errors.New("bad header field")
			}
			u = binary.LittleEndian.Uint32(b[i:])
			i += 4
		default:
			return fmt.Errorf("header field of type %q", sig)
		}
		if err != nil {
			return err
		}
		switch code {
		case 1:
			m.path = s
		case 3:
			m.member = s
		case 4:
			m.errName = s
		case 5:
			m.replySerial = u
		case 8:
			m.sig = s
		}
	}
	return nil
}

func align(i, n int) int { return (i + n - 1) &^ (n - 1) }

func str(b []byte, i int) (string, int, error) {
	i = align(i, 4)
	if i+4 > len(b) {
		return "", i, errors.New("short string")
	}
	n := int(binary.LittleEndian.Uint32(b[i:]))
	i += 4
	if n < 0 || i+n+1 > len(b) {
		return "", i, errors.New("short string")
	}
	return string(b[i : i+n]), i + n + 1, nil
}

func sigStr(b []byte, i int) (string, int, error) {
	if i >= len(b) {
		return "", i, errors.New("short signature")
	}
	n := int(b[i])
	if i+1+n+1 > len(b) {
		return "", i, errors.New("short signature")
	}
	return string(b[i+1 : i+1+n]), i + 1 + n + 1, nil
}

// variant decodes a reply body of signature "v" holding a basic type. The body starts 8-aligned
// in the message, so alignment counted from the body is the same.
func variant(b []byte, sig string) (string, error) {
	if sig != "v" {
		return "", fmt.Errorf("reply of signature %q", sig)
	}
	t, i, err := sigStr(b, 0)
	if err != nil {
		return "", err
	}
	need := func(n int) error {
		if i+n > len(b) {
			return errors.New("short value")
		}
		return nil
	}
	switch t {
	case "s", "o":
		s, _, err := str(b, i)
		return s, err
	case "t", "x":
		i = align(i, 8)
		if err := need(8); err != nil {
			return "", err
		}
		v := binary.LittleEndian.Uint64(b[i:])
		if t == "t" {
			if v == math.MaxUint64 {
				return "", nil // infinity / [not set]
			}
			return strconv.FormatUint(v, 10), nil
		}
		return strconv.FormatInt(int64(v), 10), nil
	case "u", "i", "b":
		i = align(i, 4)
		if err := need(4); err != nil {
			return "", err
		}
		v := binary.LittleEndian.Uint32(b[i:])
		switch t {
		case "i":
			return strconv.FormatInt(int64(int32(v)), 10), nil
		case "b":
			if v != 0 {
				return "yes", nil
			}
			return "no", nil
		}
		return strconv.FormatUint(uint64(v), 10), nil
	}
	return "", fmt.Errorf("value of type %q", t)
}
