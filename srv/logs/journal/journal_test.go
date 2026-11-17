package journal

import (
	"strings"
	"testing"
	"unicode/utf8"
)

func TestDisplay(t *testing.T) {
	for raw, want := range map[string]string{
		`"plain"`:                 "plain",
		`"a\nb\rc\td\be\ff"`:      `a\nb\rc` + "\t" + `d^He^Lf`,
		`"\u001b[2J\u0007\u007f"`: "^[[2J^G^?",
		`"\u0085 \u00e9 \u20ac"`:  `\x85 é €`,
		`"\ud83d\ude00"`:          "??",
		`"\uZZZZ \u12"`:           "? ^R", // \u takes 4 characters, hex or not
		`"\u0009"`:                "\t",
		`"\"q\" \\ \/"`:           `"q" \ /`,
		`"end\"`:                  "end", // (not valid JSON; a lone backslash at the end is dropped)
		`[104,105]`:               "hi",
		`[27,91,9,127,0]`:         "^[[\t^?^@",
		`[194,155,195,169]`:       `\xc2\x9bé`,
		`[226,130,172]`:           "€",
		`[226,130]`:               `\xe2\x82`,
		`[240,159,152,128]`:       "😀",
		`[237,160,128]`:           `\xed\xa0\x80`,
		`[192,175]`:               `\xc0\xaf`,
		`[245,128,128,128]`:       `\xf5\x80\x80\x80`,
		`[300]`:                   `\x12c`,
		`[]`:                      "",
		`[,]`:                     "^@^@",
		`null`:                    "[message over 4096 bytes, not shown]",
		``:                        "",
		`123`:                     "",
	} {
		if got := string(Display(nil, []byte(raw))); got != want {
			t.Errorf("Display(%s) = %q, want %q", raw, got, want)
		}
	}
}

func TestTextLevel(t *testing.T) {
	for m, want := range map[string]int{
		`{"level":"error","msg":"x"}`: 3, `{"severity": "WARNING"}`: 4, `{"lvl":"verbose"}`: -1, `{"level":30}`: 6,
		`{"level": 50}`: 3, `{"level":60}`: 2, `{"level":10}`: 7, "A6 WARN something": 4, "xERROR no": -1,
		"1ERROR yes": 3, "CRITICAL!": 2, "WARNING: x": 4, "[error] x": 3, "warning: x": 4, "warn] x": 4,
		"error x": -1, "TypeError: x": 3, "Uncaught y": 3, "Unhandled z": 3, "typeError: x": -1,
		strings.Repeat("x", 300) + " ERROR": -1, "": -1, "NOTICE": 5, "TRACE": 7, "info] x": 6,
	} {
		if got := TextLevel([]byte(m)); got != want {
			t.Errorf("TextLevel(%.40q) = %d, want %d", m, got, want)
		}
	}
}

func TestParseHostile(t *testing.T) {
	p := NewParser()
	var e Entry
	for _, l := range []string{"", "{", "[]", "null", `{"MESSAGE":}`, `{"MESSAGE":"a"`, `{"MESSAGE":"a","MESSAGE":"b"}`,
		`{"MESSAGE":"\xff\xfe"}`, `{"_PID":"1","UNIT":"x"} trailing`, strings.Repeat("[", 20000)} {
		p.Parse([]byte(l), &e)
	}
	if !p.Parse([]byte(`{"MESSAGE":"a","MESSAGE":"b"}`), &e) || string(e.Message) != `"a"` {
		t.Fatalf("a repeated field keeps its first value: %q", e.Message)
	}
}

func FuzzEntry(f *testing.F) {
	f.Add([]byte(`{"__CURSOR":"s=1","__REALTIME_TIMESTAMP":"1794587950000000","MESSAGE":"TypeError: \u001b x","PRIORITY":"3","_SYSTEMD_UNIT":"tando-a.service","_PID":"5"}`))
	f.Add([]byte(`{"MESSAGE":[27,194,155,255],"_PID":"1","UNIT":"tando-a.service"}`))
	f.Fuzz(func(t *testing.T, line []byte) {
		p := NewParser()
		var e Entry
		if !p.Parse(line, &e) {
			return
		}
		for _, json := range []bool{false, true} {
			fl := &Filter{Roles: map[string]string{"tando-a.service": "app"}, JSON: json, Level: -1, Cursor: true}
			out, _, ok := fl.Line(nil, &e)
			if !ok {
				continue
			}
			for _, c := range out {
				if c == '\n' || c == '\r' || c == 0x1b || c == 0x07 {
					t.Fatalf("a control character reached the output: %q", out)
				}
			}
			if json && utf8.Valid(line) && !utf8.Valid(out) {
				// arrays are shown by valid sequence or \xHH; strings stay as they were
				t.Logf("invalid UTF-8 out of a valid line: %q", out)
			}
		}
	})
}
