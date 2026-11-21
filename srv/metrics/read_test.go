package metrics

import (
	"bytes"
	"testing"

	"tando/srv/internal/out"
)

func (h *host) readOut(args ...string) string {
	h.t.Helper()
	a, err := ParseReadArgs(args)
	if err != nil {
		h.t.Fatal(err)
	}
	var b bytes.Buffer
	w := out.New(&b)
	h.m.Read(w, a)
	if err := w.Flush(); err != nil {
		h.t.Fatal(err)
	}
	return b.String()
}

func TestReadApp(t *testing.T) {
	h := newHost(t)
	h.now = 1_800_000_300 // window of 5 one-minute buckets: from 1800000060
	h.write("lib/metrics/web.tsv.1", ""+
		"1799999880\t100\t0\t0\tr\n"+ // beyond the 7 lines read
		"1799999940\t100\t60000000\t0\tr\n")
	h.write("lib/metrics/web.tsv", ""+
		"1800000000\t1000\t60000000\t0\tr\n"+ // before the window, but the next line's dt counts from it
		"1800000060\t2000\t30000000\t1\tr\n"+ // 30 s of cpu in 60 s: 500 permille
		"not a sample\n"+
		"1800000120\t3000\t1200000\t2\tf\n"+ // 20 permille
		"1800000150\t5000\t600000\t1\ta\n"+ // 0.6 s in 30 s: 20 permille; same bucket
		"1800000280\t9000\t9") // still being written: not read
	want := "mx\t60\t1800000300\n" +
		"m\t1800000060\t2000\t500\t1\tr\t-\t-\t-\t-\t-\t-\n" +
		"m\t1800000120\t4000\t20\t2\ta\t-\t-\t-\t-\t-\t-\n"
	if got := h.readOut("web", "5", "60"); got != want {
		t.Errorf("got\n%s\nwant\n%s", got, want)
	}
}

func TestReadGaps(t *testing.T) {
	h := newHost(t)
	h.now = 1_800_003_000
	// more than 10 minutes since the previous sample (the host was down), or time going
	// backwards: the difference is taken as one minute's
	h.write("lib/metrics/web.tsv", ""+
		"1800000000\t1\t0\t0\tr\n"+
		"1800001000\t1\t6000000\t0\tr\n"+
		"1800000990\t1\t6000000\t0\tr\n")
	want := "mx\t3600\t1800003000\n" + "m\t1800000000\t1\t66\t0\tr\t-\t-\t-\t-\t-\t-\n"
	if got := h.readOut("web", "1", "3600"); got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestReadHost(t *testing.T) {
	h := newHost(t)
	h.now = 1_800_000_300
	h.write("lib/metrics/host.tsv", ""+
		"1799999940\t10\t100\t1000\n"+
		"1800000000\t20\t200\t1000\n"+
		"1800000060\t40\t400\t1000\n"+
		"1800000300\t60\t600\t2000\n")
	want := "mx\t300\t1800000300\n" +
		"h\t1800000000\t30\t300\t1000\t-\t-\t-\n" +
		"h\t1800000300\t60\t600\t2000\t-\t-\t-\n"
	if got := h.readOut("host", "2", "300"); got != want {
		t.Errorf("got\n%s\nwant\n%s", got, want)
	}
}

func TestReadNothing(t *testing.T) {
	h := newHost(t)
	if got := h.readOut("web", "", ""); got != "mx\t60\t1800000000\n" {
		t.Errorf("got %q", got)
	}
}

func TestParseReadArgs(t *testing.T) {
	tests := []struct {
		args    []string
		want    ReadArgs
		wantErr string
	}{
		{[]string{"web", "60", "60"}, ReadArgs{"web", 60, 60}, ""},
		{[]string{"host"}, ReadArgs{"host", 60, 60}, ""},
		{[]string{"web", "2000", "86400", "extra"}, ReadArgs{"web", 2000, 86400}, ""},
		{[]string{"web", "", "300"}, ReadArgs{"web", 60, 300}, ""},
		{[]string{"web", "010", "060"}, ReadArgs{"web", 10, 60}, ""}, // decimal, not octal
		{nil, ReadArgs{}, "bad app name"},
		{[]string{"../x", "5", "60"}, ReadArgs{}, "bad app name"},
		{[]string{"Web"}, ReadArgs{}, "bad app name"},
		{[]string{"web", "0"}, ReadArgs{}, "bad point count"},
		{[]string{"web", "2001"}, ReadArgs{}, "bad point count"},
		{[]string{"web", "-1"}, ReadArgs{}, "bad point count"},
		{[]string{"web", "5", "59"}, ReadArgs{}, "bad bucket"},
		{[]string{"web", "5", "86401"}, ReadArgs{}, "bad bucket"},
		{[]string{"web", "5", "1m"}, ReadArgs{}, "bad bucket"},
	}
	for _, tt := range tests {
		got, err := ParseReadArgs(tt.args)
		if tt.wantErr != "" {
			if err == nil || err.Error() != tt.wantErr {
				t.Errorf("%q: error %v, want %q", tt.args, err, tt.wantErr)
			}
			continue
		}
		if err != nil || got != tt.want {
			t.Errorf("%q: %+v, %v", tt.args, got, err)
		}
	}
}

func TestTail(t *testing.T) {
	tests := []struct {
		in   string
		n    int64
		want string
	}{
		{"a\nb\nc\n", 2, "b\nc\n"},
		{"a\nb\nc\n", 3, "a\nb\nc\n"},
		{"a\nb\nc\n", 9, "a\nb\nc\n"},
		{"a\nb\nc", 1, "c"},
		{"a\nb\nc", 2, "b\nc"},
		{"", 3, ""},
		{"a\n", 0, ""},
	}
	for _, tt := range tests {
		if got := string(tail([]byte(tt.in), tt.n)); got != tt.want {
			t.Errorf("tail(%q, %d) = %q, want %q", tt.in, tt.n, got, tt.want)
		}
	}
}

func TestFields(t *testing.T) {
	tests := []struct {
		in   string
		want [10]string
	}{
		{"1\t2\t3\t4\tr", [10]string{"1", "2", "3", "4", "r"}},
		{"1\t2\t3\t4", [10]string{"1", "2", "3", "4", ""}},
		{"\t1\t\t2\t3\t4\tr\t", [10]string{"1", "2", "3", "4", "r"}}, // runs of tabs are one separator
		// the state is the fifth field alone: the slice's columns follow it (since 2026-11)
		{"1\t2\t3\t4\tr\t5\t-\t7\t8\t9\tlater", [10]string{"1", "2", "3", "4", "r", "5", "-", "7", "8", "9"}},
		{"", [10]string{}},
	}
	for _, tt := range tests {
		if got := fields(tt.in); got != tt.want {
			t.Errorf("fields(%q) = %q, want %q", tt.in, got, tt.want)
		}
	}
}

// host lines with cpu permille and disk used/total; older lines without them are gaps ("-")
func TestReadHostCPUDisk(t *testing.T) {
	h := newHost(t)
	h.now = 1_800_000_300
	h.write("lib/metrics/host.tsv", ""+
		"1800000000\t20\t200\t1000\n"+ // an older version's line
		"1800000060\t40\t400\t1000\t-\t50\t100\n"+ // the first sample after an upgrade: no cpu yet
		"1800000120\t40\t400\t1000\t300\t60\t100\n"+
		"1800000180\t40\t400\t1000\t100\t70\t200\n"+
		"1800000300\t60\t600\t2000\n")
	want := "mx\t300\t1800000300\n" +
		"h\t1800000000\t35\t350\t1000\t200\t60\t200\n" +
		"h\t1800000300\t60\t600\t2000\t-\t-\t-\n"
	if got := h.readOut("host", "2", "300"); got != want {
		t.Errorf("got\n%s\nwant\n%s", got, want)
	}
}

// app rows gain the disk bytes: the newest walk (<app>.disk, one line per 15 min or less) at or
// before the bucket's end, if it is at most 20 minutes older than the bucket's start
func TestReadAppDisk(t *testing.T) {
	h := newHost(t)
	h.now = 1_800_003_600
	h.write("lib/metrics/web.disk.1", "1799990000\t5\n")
	h.write("lib/metrics/web.disk", "1800000000\t1000\n1800000900\t2000\n")
	h.write("lib/metrics/web.tsv", ""+
		"1799999940\t1\t0\t0\tr\n"+ // before the first walk: no disk
		"1800000060\t1\t0\t0\tr\n"+ // the 1800000000 walk
		"1800000960\t1\t0\t0\tr\n"+ // the 1800000900 walk
		"1800003500\t1\t0\t0\tr\n") // the last walk is 43 min old: no disk
	got := h.readOut("web", "60", "60")
	want := "mx\t60\t1800003600\n" +
		"m\t1800000060\t1\t0\t0\tr\t1000\t-\t-\t-\t-\t-\n" +
		"m\t1800000960\t1\t0\t0\tr\t2000\t-\t-\t-\t-\t-\n" +
		"m\t1800003480\t1\t0\t0\tr\t-\t-\t-\t-\t-\t-\n"
	if got != want {
		t.Errorf("got\n%s\nwant\n%s", got, want)
	}
}
