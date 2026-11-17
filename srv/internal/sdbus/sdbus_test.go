package sdbus

import (
	"bufio"
	"encoding/binary"
	"io"
	"math"
	"net"
	"strings"
	"testing"
)

func TestUnitPath(t *testing.T) {
	for in, want := range map[string]string{
		"tando-hello-2.service":                 "/org/freedesktop/systemd1/unit/tando_2dhello_2d2_2eservice",
		"tando-web-act-20261114-170102.service": "/org/freedesktop/systemd1/unit/tando_2dweb_2dact_2d20261114_2d170102_2eservice",
		"2x":                                    "/org/freedesktop/systemd1/unit/_32x",
		"":                                      "/org/freedesktop/systemd1/unit/_",
	} {
		if got := UnitPath(in); got != want {
			t.Errorf("%q: %s", in, got)
		}
	}
}

// appendReturn: a method return to serial whose body is a variant of type sig.
func appendReturn(w []byte, serial, replyTo uint32, sig string, val any) []byte {
	start := len(w)
	w = append(w, 'l', typeReturn, 1, 1)
	w = binary.LittleEndian.AppendUint32(w, 0)
	w = binary.LittleEndian.AppendUint32(w, serial)
	w = binary.LittleEndian.AppendUint32(w, 0)
	f := len(w)
	w = append(w, 5, 1, 'u', 0)
	w = binary.LittleEndian.AppendUint32(w, replyTo)
	w = pad(w, start, 8)
	w = append(w, 8, 1, 'g', 0, 1, 'v', 0)
	binary.LittleEndian.PutUint32(w[f-4:], uint32(len(w)-f))
	w = pad(w, start, 8)
	body := len(w)
	w = append(w, byte(len(sig)))
	w = append(w, sig...)
	w = append(w, 0)
	switch v := val.(type) {
	case string:
		w = pad(w, start, 4)
		w = binary.LittleEndian.AppendUint32(w, uint32(len(v)))
		w = append(w, v...)
		w = append(w, 0)
	case uint64:
		w = pad(w, start, 8)
		w = binary.LittleEndian.AppendUint64(w, v)
	case uint32:
		w = pad(w, start, 4)
		w = binary.LittleEndian.AppendUint32(w, v)
	}
	binary.LittleEndian.PutUint32(w[start+4:], uint32(len(w)-body))
	return w
}

func appendError(w []byte, serial, replyTo uint32, name string) []byte {
	start := len(w)
	w = append(w, 'l', typeError, 1, 1)
	w = binary.LittleEndian.AppendUint32(w, 0)
	w = binary.LittleEndian.AppendUint32(w, serial)
	w = binary.LittleEndian.AppendUint32(w, 0)
	f := len(w)
	w = append(w, 4, 1, 's', 0)
	w = binary.LittleEndian.AppendUint32(w, uint32(len(name)))
	w = append(w, name...)
	w = append(w, 0)
	w = pad(w, start, 8)
	w = append(w, 5, 1, 'u', 0)
	w = binary.LittleEndian.AppendUint32(w, replyTo)
	binary.LittleEndian.PutUint32(w[f-4:], uint32(len(w)-f))
	w = pad(w, start, 8)
	return w
}

// fakeSystemd answers Gets from props (path -> name -> value; "error" answers an error). rounds
// are the number of calls the client sends at once; each round is answered in reverse order.
func fakeSystemd(t *testing.T, conn net.Conn, props map[string]map[string]any, calls *[]string, rounds ...int) {
	r := bufio.NewReader(conn)
	l, _ := r.ReadString('\n')
	if !strings.HasPrefix(l, "\x00AUTH EXTERNAL ") {
		t.Errorf("auth line %q", l)
	}
	io.WriteString(conn, "OK 0123456789abcdef\r\n")
	if l, _ := r.ReadString('\n'); l != "BEGIN\r\n" {
		t.Errorf("begin %q", l)
	}
	if m, err := readMsg(r); err != nil || m.member != "Ping" || m.path != "/" {
		t.Errorf("first message %+v %v", m, err)
	}
	for _, n := range rounds {
		var out [][]byte
		for k := 0; k < n; k++ {
			m, err := readMsg(r)
			if err != nil {
				return
			}
			if m.typ == typeCall && m.member == "ListUnitsByPatterns" {
				if m.sig != "asas" || m.path != "/org/freedesktop/systemd1" {
					t.Errorf("list call %+v", m)
				}
				*calls = append(*calls, "list")
				out = append(out, appendUnitList(nil, 1000+m.serial, m.serial, props["loaded"]))
				continue
			}
			if m.typ != typeCall || m.member != "Get" || m.sig != "ss" {
				t.Errorf("call %+v", m)
			}
			_, i, _ := str(m.body, 0)
			name, _, _ := str(m.body, i)
			*calls = append(*calls, m.path+" "+name)
			var b []byte
			switch v := props[m.path][name].(type) {
			case string:
				if v == "error" {
					b = appendError(nil, 1000+m.serial, m.serial, "org.freedesktop.DBus.Error.UnknownProperty")
				} else {
					b = appendReturn(nil, 1000+m.serial, m.serial, "s", v)
				}
			case uint64:
				b = appendReturn(nil, 1000+m.serial, m.serial, "t", v)
			case uint32:
				b = appendReturn(nil, 1000+m.serial, m.serial, "u", v)
			default:
				b = appendError(nil, 1000+m.serial, m.serial, "org.freedesktop.DBus.Error.UnknownProperty")
			}
			out = append(out, b)
		}
		for k := len(out) - 1; k >= 0; k-- {
			conn.Write(out[k])
		}
	}
}

func TestGet(t *testing.T) {
	a, b := net.Pipe()
	web, gone := UnitPath("tando-web.service"), UnitPath("tando-gone.service")
	var calls []string
	go fakeSystemd(t, b, map[string]map[string]any{
		web:  {"ActiveState": "active", "MemoryMax": uint64(134217728), "CPUUsageNSec": uint64(2500000000), "NRestarts": uint32(3), "ActiveEnterTimestampMonotonic": uint64(12345)},
		gone: {"ActiveState": "inactive", "MemoryMax": uint64(math.MaxUint64), "CPUUsageNSec": uint64(math.MaxUint64), "NRestarts": uint32(0), "ActiveEnterTimestampMonotonic": uint64(0)},
	}, &calls, 15, 1)
	c, err := NewConn(a, 0, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	props := []Prop{{"org.freedesktop.systemd1.Unit", "ActiveState"}, {"org.freedesktop.systemd1.Service", "MemoryMax"},
		{"org.freedesktop.systemd1.Service", "CPUUsageNSec"}, {"org.freedesktop.systemd1.Service", "NRestarts"},
		{"org.freedesktop.systemd1.Unit", "ActiveEnterTimestampMonotonic"}}
	got, err := c.Get([]string{"tando-web.service", "tando-gone.service", "tando-web.service"}, props)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"ActiveEnterTimestampMonotonic=12345 ActiveState=active CPUUsageNSec=2500000000 MemoryMax=134217728 NRestarts=3",
		"ActiveEnterTimestampMonotonic=0 ActiveState=inactive CPUUsageNSec= MemoryMax= NRestarts=0",
		"ActiveEnterTimestampMonotonic=12345 ActiveState=active CPUUsageNSec=2500000000 MemoryMax=134217728 NRestarts=3",
	}
	for i, m := range got {
		var kv []string
		for _, k := range []string{"ActiveEnterTimestampMonotonic", "ActiveState", "CPUUsageNSec", "MemoryMax", "NRestarts"} {
			kv = append(kv, k+"="+m[k])
		}
		if s := strings.Join(kv, " "); s != want[i] {
			t.Errorf("unit %d: %s", i, s)
		}
	}
	if len(calls) != 15 || calls[0] != web+" ActiveState" {
		t.Errorf("calls %v", calls)
	}
	// a second round on the same connection; an error answer is an error
	got, err = c.Get([]string{"tando-web.service"}, []Prop{{"org.freedesktop.systemd1.Unit", "Nope"}})
	if err == nil || !strings.Contains(err.Error(), "Nope") {
		t.Errorf("error answer: %v %v", got, err)
	}
}

func TestAuthRefused(t *testing.T) {
	a, b := net.Pipe()
	go func() {
		r := bufio.NewReader(b)
		r.ReadString('\n')
		io.WriteString(b, "REJECTED EXTERNAL\r\n")
		b.Close()
	}()
	if _, err := NewConn(a, 1000, nil); err == nil || !strings.Contains(err.Error(), "REJECTED") {
		t.Errorf("err %v", err)
	}
}

func TestCallRoundTrip(t *testing.T) {
	w := appendCall(nil, 42, "/org/freedesktop/systemd1/unit/x", "org.freedesktop.systemd1.Unit", "ActiveState")
	m, err := readMsg(bufio.NewReader(strings.NewReader(string(w))))
	if err != nil || m.serial != 42 || m.path != "/org/freedesktop/systemd1/unit/x" || m.member != "Get" || m.sig != "ss" {
		t.Fatalf("%+v %v", m, err)
	}
	a, i, _ := str(m.body, 0)
	b, _, _ := str(m.body, i)
	if a != "org.freedesktop.systemd1.Unit" || b != "ActiveState" {
		t.Errorf("body %q %q", a, b)
	}
	for _, bad := range []string{"", "B\x01\x00\x01", strings.Repeat("l", 16)} {
		if _, err := readMsg(bufio.NewReader(strings.NewReader(bad))); err == nil {
			t.Errorf("%q: no error", bad)
		}
	}
}

// appendUnitList: the reply to ListUnitsByPatterns, one unit per key of loaded (value: its state).
func appendUnitList(w []byte, serial, replyTo uint32, loaded map[string]any) []byte {
	start := len(w)
	w = append(w, 'l', typeReturn, 1, 1)
	w = binary.LittleEndian.AppendUint32(w, 0)
	w = binary.LittleEndian.AppendUint32(w, serial)
	w = binary.LittleEndian.AppendUint32(w, 0)
	f := len(w)
	w = append(w, 5, 1, 'u', 0)
	w = binary.LittleEndian.AppendUint32(w, replyTo)
	w = pad(w, start, 8)
	sig := "a(ssssssouso)"
	w = append(w, 8, 1, 'g', 0, byte(len(sig)))
	w = append(w, sig...)
	w = append(w, 0)
	binary.LittleEndian.PutUint32(w[f-4:], uint32(len(w)-f))
	w = pad(w, start, 8)
	body := len(w)
	lenAt := len(w)
	w = binary.LittleEndian.AppendUint32(w, 0)
	w = pad(w, start, 8)
	elems := len(w)
	s := func(v string) {
		w = pad(w, start, 4)
		w = binary.LittleEndian.AppendUint32(w, uint32(len(v)))
		w = append(w, v...)
		w = append(w, 0)
	}
	for _, name := range sortedKeys(loaded) {
		w = pad(w, start, 8)
		s(name)
		s("desc of " + name)
		s("loaded")
		s(loaded[name].(string))
		s("running")
		s("")
		s(UnitPath(name))
		w = pad(w, start, 4)
		w = binary.LittleEndian.AppendUint32(w, 7)
		s("")
		s("/")
	}
	binary.LittleEndian.PutUint32(w[lenAt:], uint32(len(w)-elems))
	binary.LittleEndian.PutUint32(w[start+4:], uint32(len(w)-body))
	return w
}

func sortedKeys(m map[string]any) []string {
	var k []string
	for x := range m {
		k = append(k, x)
	}
	for i := range k {
		for j := i + 1; j < len(k); j++ {
			if k[j] < k[i] {
				k[i], k[j] = k[j], k[i]
			}
		}
	}
	return k
}

func TestUnitProps(t *testing.T) {
	a, b := net.Pipe()
	web, halt := UnitPath("tando-web.service"), UnitPath("tando-halt.service")
	var calls []string
	props := []Prop{{"org.freedesktop.systemd1.Unit", "ActiveState"}, {"org.freedesktop.systemd1.Service", "MemoryMax"},
		{"org.freedesktop.systemd1.Service", "CPUUsageNSec"}, {"org.freedesktop.systemd1.Service", "NRestarts"},
		{"org.freedesktop.systemd1.Unit", "ActiveEnterTimestampMonotonic"}}
	go fakeSystemd(t, b, map[string]map[string]any{
		"loaded":                         {"tando-web.service": "active", "tando-web-job-x.service": "inactive", "tando-crashy.service": "failed"},
		web:                              {"ActiveState": "active", "MemoryMax": uint64(134217728), "CPUUsageNSec": uint64(25), "NRestarts": uint32(3), "ActiveEnterTimestampMonotonic": uint64(12345)},
		UnitPath("tando-crashy.service"): {"ActiveState": "failed", "MemoryMax": uint64(math.MaxUint64), "CPUUsageNSec": uint64(9), "NRestarts": uint32(9), "ActiveEnterTimestampMonotonic": uint64(1)},
		halt:                             {"MemoryMax": uint64(268435456)},
		UnitPath("tando-site.service"):   {"MemoryMax": uint64(math.MaxUint64)},
	}, &calls, 1, 10, 2)
	c, err := NewConn(a, 0, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	got, err := c.UnitProps([]string{"tando-halt.service", "tando-web.service", "tando-site.service", "tando-crashy.service"}, props, nil)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"inactive 268435456  0 0",
		"active 134217728 25 3 12345",
		"inactive   0 0",
		"failed  9 9 1",
	}
	for i, m := range got {
		s := strings.Join([]string{m["ActiveState"], m["MemoryMax"], m["CPUUsageNSec"], m["NRestarts"], m["ActiveEnterTimestampMonotonic"]}, " ")
		if s != want[i] {
			t.Errorf("unit %d: %q, want %q", i, s, want[i])
		}
	}
	// the stopped and the unknown unit: only MemoryMax asked, once each
	n := 0
	for _, x := range calls {
		if strings.HasPrefix(x, halt+" ") || strings.HasPrefix(x, UnitPath("tando-site.service")+" ") {
			n++
			if !strings.HasSuffix(x, " MemoryMax") {
				t.Errorf("asked %s", x)
			}
		}
	}
	if n != 2 || calls[0] != "list" {
		t.Errorf("calls %v", calls)
	}
}

// A unit that is not loaded and whose file says its MemoryMax is not asked at all.
func TestUnitPropsFromFile(t *testing.T) {
	a, b := net.Pipe()
	var calls []string
	go fakeSystemd(t, b, map[string]map[string]any{
		"loaded":                       {},
		UnitPath("tando-site.service"): {"MemoryMax": uint64(math.MaxUint64)},
	}, &calls, 1, 1)
	c, err := NewConn(a, 0, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	got, err := c.UnitProps([]string{"tando-halt.service", "tando-site.service"},
		[]Prop{{"org.freedesktop.systemd1.Unit", "ActiveState"}, {"org.freedesktop.systemd1.Service", "MemoryMax"}},
		func(unit, prop string) (string, bool) { return "268435456", unit == "tando-halt.service" })
	if err != nil {
		t.Fatal(err)
	}
	if got[0]["MemoryMax"] != "268435456" || got[0]["ActiveState"] != "inactive" || got[1]["MemoryMax"] != "" {
		t.Errorf("%v", got)
	}
	if strings.Join(calls, ",") != "list,"+UnitPath("tando-site.service")+" MemoryMax" {
		t.Errorf("calls %v", calls)
	}
}
