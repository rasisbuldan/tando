package errscan

import (
	"fmt"
	"regexp"
	"strings"
	"testing"
)

func TestNorm(t *testing.T) {
	for in, want := range map[string]string{
		"timeout after 100 ms":                      "timeout after <n> ms",
		"0x1f at 0xC000":                            "<hex> at <hex>",
		"00x12 0x 0xZZ":                             "<n><hex> <n>x <n>xZZ",
		"id 9f86d081884c7d65 x":                     "id <id> x",
		"uuid 550e8400-e29b-41d4-a716-446655440000": "uuid <id>-e<n>b-<n>d<n>-a<n>-<id>", // short parts are not ids
		"deadbeef-cafebabe1":                        "deadbeef-<id>", "1234abcd-cafebab1": "<id>",
		"abcdefab no digit":               "abcdefab no digit",
		"xdeadbeefcafe12y deadbeefcafe12": "x<id>y deadbeefcafe<n>",
		"<id>-<id> literal":               "<id> literal",
		"":                                "",
	} {
		if got := Norm(in); got != want {
			t.Errorf("Norm(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestID(t *testing.T) {
	// values the shell version computed (golden), so ids already on servers stay the same
	for fp, id := range map[string]string{"node|ValidationException|": "7432227d", "": "00001505"} {
		if got := ID(fp); got != id {
			t.Errorf("ID(%q) = %s, want %s", fp, got, id)
		}
	}
}

func events(in string) []Event {
	var ev []Event
	s := &Scanner{Emit: func(e Event) { ev = append(ev, e) }}
	for l := range strings.SplitSeq(in, "\n") {
		s.Line([]byte(l))
	}
	s.End()
	return ev
}

func TestScanner(t *testing.T) {
	const h = "1794587950.000000 host node[7]: "
	for _, c := range []struct {
		lines []string
		want  []string // label | fingerprint
	}{
		{[]string{"TypeError: Cannot read properties of null (reading 'foo')",
			"    at Layer.handle (/srv/node_modules/express/lib/router/layer.js:95:5)",
			"    at nodeErr (/opt/tando/apps/boom/releases/20261115-013512/server.js:12:7)"},
			[]string{"TypeError at nodeErr (server.js)|node|TypeError|nodeErr (server.js)"}},
		{[]string{"Traceback (most recent call last):", `  File "/srv/app/views.py", line 41, in checkout`,
			`    total = cart["total"]`, `  File "/usr/lib/python3.12/site-packages/x.py", line 1, in y`, "KeyError: 'total'"},
			[]string{"KeyError at /srv/app/views.py:checkout|py|KeyError|/srv/app/views.py:checkout"}},
		{[]string{"panic: runtime error: index out of range [5] with length 3", "", "goroutine 1 [running]:",
			"runtime.gopanic(0x1)", "main.handler(0xc000012345)", "\t/home/dev/app/main.go:42 +0x1d", "exit status 2"},
			[]string{"Go panic at main.handler|go|Go panic|main.handler|runtime error: index out of range [<n>] with length <n>"}},
		{[]string{"ERROR db timeout after 100 ms", "ERROR db timeout after 101 ms"},
			[]string{"error line|line|ERROR db timeout after <n> ms", "error line|line|ERROR db timeout after <n> ms"}},
		{[]string{"ERROR Exception in handler", "Traceback (most recent call last):", `  File "/srv/a.py", line 1, in f`, "ValueError: x"},
			[]string{"ValueError at /srv/a.py:f|py|ValueError|/srv/a.py:f"}},
		{[]string{"all good", "GET /health 200"}, nil},
	} {
		var in []string
		for _, l := range c.lines {
			in = append(in, h+l)
		}
		var got []string
		for _, e := range events(strings.Join(in, "\n")) {
			got = append(got, e.Label+"|"+e.Fingerprint)
		}
		if fmt.Sprint(got) != fmt.Sprint(c.want) {
			t.Errorf("%q:\n got %q\nwant %q", c.lines[0], got, c.want)
		}
	}
	// another process, or more than 2 s later, starts over
	ev := events("1.0 h a[1]: TypeError: x\n1.0 h a[2]:     at f (/a.js:1:1)\n9.0 h a[1]:     at g (/b.js:1:1)")
	if len(ev) != 1 || ev[0].Label != "TypeError" {
		t.Fatalf("%+v", ev)
	}
}

func FuzzScanner(f *testing.F) {
	f.Add([]byte("1794587950.1 host node[7]: TypeError: x\n1794587950.2 host node[7]:     at f (/a.js:1:2)\n"))
	f.Add([]byte("1 h systemd-journald[1]: Suppressed 5 messages\n-- cursor: s=1\n"))
	f.Fuzz(func(t *testing.T, in []byte) {
		tb := &Table{Now: 1794590000}
		s := &Scanner{Emit: func(e Event) {
			if len(e.ID) != 8 || len(e.Title) > 240 || len(e.Label) > 240 || len(e.Sample) > 30 {
				t.Fatalf("event out of bounds: %+v", e)
			}
			if strings.ContainsAny(e.Title+e.Label+e.Fingerprint, "\t\n") {
				t.Fatalf("a tab or newline in an event: %+v", e)
			}
			tb.Add(e)
		}}
		for l := range strings.SplitSeq(string(in), "\n") {
			s.Line([]byte(l))
		}
		s.End()
		r := tb.Result()
		tb2 := &Table{Now: 1794590000}
		tb2.Load(r.Data)
		Window(r.Data, 0, 10)
	})
}

// hasWord is the shell's regex, without the regex
func FuzzWord(f *testing.F) {
	re := regexp.MustCompile(`(^|[^a-z])(error|exception|panic|traceback|unhandled|fatal|critical)([^a-z]|$)`)
	for _, s := range []string{"error", "errors error", "xerror", "an Error!", "typeerror: x", "fatal", "é panic é", "criticals"} {
		f.Add([]byte(s))
	}
	f.Fuzz(func(t *testing.T, m []byte) {
		l := lowerInto(nil, m)
		if hasWord(l) != re.Match(l) {
			t.Fatalf("%q: hasWord %v, regex %v", l, hasWord(l), re.Match(l))
		}
	})
}
