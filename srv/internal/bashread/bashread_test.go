package bashread

import (
	"strings"
	"testing"
)

func TestLines(t *testing.T) {
	for in, want := range map[string][2]string{
		"":           {"", ""},
		"a":          {"", "a"},
		"a\nb\nc":    {"a,b", "a,b,c"}, // bash's read drops the unterminated "c"; grep and awk do not
		"a\nb\n":     {"a,b", "a,b"},
		"\n\n":       {",", ","},
		"x=1\r\ny=2": {"x=1\r", "x=1\r,y=2"},
	} {
		if got := strings.Join(Lines([]byte(in)), ","); got != want[0] {
			t.Errorf("Lines(%q) = %q, want %q", in, got, want[0])
		}
		if got := strings.Join(LinesAll([]byte(in)), ","); got != want[1] {
			t.Errorf("LinesAll(%q) = %q, want %q", in, got, want[1])
		}
	}
	if Lines([]byte("no newline")) != nil || LinesAll(nil) != nil {
		t.Error("nil when there is no line")
	}
}

func TestFields(t *testing.T) {
	for _, tt := range []struct {
		in   string
		n    int
		want []string
	}{
		{"a\tb\tc\td e\tf", 5, []string{"a", "b", "c", "d e", "f"}},
		{"a\t\tb", 3, []string{"a", "b", ""}}, // a run of tabs is one separator
		{"\ta\tb\t", 2, []string{"a", "b"}},   // leading and trailing tabs go
		{"a\tb\tc\td\te\tf", 5, []string{"a", "b", "c", "d", "e\tf"}},
		{"a\t\tb\tc d\te", 3, []string{"a", "b", "c d\te"}}, // the rest goes to the last
		{"\ta\t\tb\tc d\t\te\t", 3, []string{"a", "b", "c d\t\te"}},
		{"", 3, []string{"", "", ""}},
		{"only", 3, []string{"only", "", ""}},
		{"\t\tone\t\t", 1, []string{"one"}},
	} {
		if got := Fields(tt.in, tt.n); strings.Join(got, "|") != strings.Join(tt.want, "|") || len(got) != tt.n {
			t.Errorf("Fields(%q, %d) = %q, want %q", tt.in, tt.n, got, tt.want)
		}
	}
}

func TestKV(t *testing.T) {
	in := "a=1\n#c=2\n=x\nnoeq\nb=x=y=\r\nn\x00ul=v\x00\na=again\nlast=unterminated"
	read := func(r KV) string {
		var b strings.Builder
		for k, v, ok := r.Next(); ok; k, v, ok = r.Next() {
			b.WriteString(k + "|" + v + ";")
		}
		return b.String()
	}
	for _, tt := range []struct {
		r    KV
		want string
	}{
		{KV{Data: in}, "a|1;#c|2;b|x=y=\r;n\x00ul|v\x00;a|again;"},
		{KV{Data: in, DropNUL: true}, "a|1;#c|2;b|x=y=\r;nul|v;a|again;"},
		{KV{Data: in, Partial: true, SkipComments: true}, "a|1;b|x=y=\r;n\x00ul|v\x00;a|again;last|unterminated;"},
		{KV{}, ""},
	} {
		if got := read(tt.r); got != tt.want {
			t.Errorf("%+v:\n got %q\nwant %q", tt.r, got, tt.want)
		}
	}
	for key, want := range map[string]string{"a": "1", "b": "x=y=\r", "last": "", "#c": "2", "zz": ""} {
		if got := First([]byte(in), key); got != want {
			t.Errorf("First(%q) = %q, want %q", key, got, want)
		}
	}
}

func FuzzKV(f *testing.F) {
	f.Add([]byte("a=1\n#c=2\n=x\nb=x=y=\r\nn\x00ul=v\x00\nlast"))
	f.Fuzz(func(t *testing.T, b []byte) {
		for _, r := range []KV{{Data: string(b)}, {Data: string(b), DropNUL: true, Partial: true, SkipComments: true}} {
			for k, v, ok := r.Next(); ok; k, v, ok = r.Next() {
				if len(k) == 0 || strings.ContainsAny(k, "=\n") || strings.Contains(v, "\n") {
					t.Fatalf("%q=%q", k, v)
				}
				if r.DropNUL && (strings.Contains(k, "\x00") || strings.Contains(v, "\x00")) {
					t.Fatal("NUL kept")
				}
			}
		}
	})
}
