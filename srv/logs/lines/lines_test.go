package lines

import (
	"bytes"
	"strings"
	"testing"
)

func readAll(in string, max int) []Line {
	r := NewReader(strings.NewReader(in), max)
	var out []Line
	for {
		l, ok := r.Next()
		if !ok {
			return out
		}
		l.Text = append([]byte(nil), l.Text...)
		out = append(out, l)
	}
}

func TestReader(t *testing.T) {
	long := strings.Repeat("x", 200000)
	for _, c := range []struct {
		in   string
		max  int
		want []Line
	}{
		{"", 10, nil},
		{"\n", 10, []Line{{Text: []byte{}, Len: 0, EOL: true}}},
		{"a\nbc", 10, []Line{{Text: []byte("a"), Len: 1, EOL: true}, {Text: []byte("bc"), Len: 2}}},
		{"abcdef\nx\n", 3, []Line{{Text: []byte("abc"), Len: 6, EOL: true}, {Text: []byte("x"), Len: 1, EOL: true}}},
		{"a\r\n", 10, []Line{{Text: []byte("a\r"), Len: 2, EOL: true}}},
		{long + "\nz\n", 1000, []Line{{Text: []byte(long[:1000]), Len: 200000, EOL: true}, {Text: []byte("z"), Len: 1, EOL: true}}},
		{long, 100000, []Line{{Text: []byte(long[:100000]), Len: 200000}}},
		{long + "\n", 300000, []Line{{Text: []byte(long), Len: 200000, EOL: true}}},
	} {
		got := readAll(c.in, c.max)
		if len(got) != len(c.want) {
			t.Fatalf("%.20q: %d lines, want %d", c.in, len(got), len(c.want))
		}
		for i := range got {
			if !bytes.Equal(got[i].Text, c.want[i].Text) || got[i].Len != c.want[i].Len || got[i].EOL != c.want[i].EOL {
				t.Errorf("%.20q line %d: %.20q %d %v, want %.20q %d %v", c.in, i, got[i].Text, got[i].Len, got[i].EOL,
					c.want[i].Text, c.want[i].Len, c.want[i].EOL)
			}
		}
	}
}

func TestNum(t *testing.T) {
	for in, want := range map[string]float64{"": 0, "abc": 0, "12": 12, "  1794587950.123456 host": 1794587950.123456,
		"-5x": -5, "+3": 3, "1e3": 1000, "1e": 1, ".5": 0.5, "5.": 5, ".": 0, "-": 0, "1.2.3": 1.2, "\t7": 7, "0x1A": 0} {
		if got := Num([]byte(in)); got != want {
			t.Errorf("Num(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestIsNum(t *testing.T) {
	for in, want := range map[string]bool{"": false, "1": true, " 1 ": true, "1.5e3": true, "1a": false, "-": false, "abc": false,
		"1794587950": true, ".": false} {
		if got := IsNum(in); got != want {
			t.Errorf("IsNum(%q) = %v", in, got)
		}
	}
}

func TestFields(t *testing.T) {
	var f [3][]byte
	n := Fields([]byte("  a b\t\tc  d e"), f[:])
	if n != 3 || string(f[0]) != "a" || string(f[1]) != "b" || string(f[2]) != "c  d e" {
		t.Fatalf("%d %q", n, f)
	}
	if n := Fields([]byte("   "), f[:]); n != 0 {
		t.Fatal(n)
	}
}

func TestStack(t *testing.T) {
	for _, limit := range []int{0, 7, 64} {
		var s Stack
		s.Limit = limit
		var want []string
		for i := 0; i < 1000; i++ {
			l := strings.Repeat(string(rune('a'+i%26)), i%37)
			s.Push([]byte(l))
			want = append([]string{l}, want...)
		}
		var b bytes.Buffer
		if err := s.WriteReversed(&b); err != nil {
			t.Fatal(err)
		}
		if got := b.String(); got != strings.Join(want, "\n")+"\n" {
			t.Fatalf("limit %d: reversed output differs (%d bytes, want %d)", limit, len(got), len(strings.Join(want, "\n"))+1)
		}
	}
	var s Stack
	var b bytes.Buffer
	if err := s.WriteReversed(&b); err != nil || b.Len() != 0 {
		t.Fatal("empty stack")
	}
}

func FuzzReader(f *testing.F) {
	f.Add([]byte("a\nbb\n\nccc"), 2)
	f.Fuzz(func(t *testing.T, in []byte, max int) {
		if max < 0 {
			max = -max
		}
		max = max%100 + 1
		total := 0
		for _, l := range readAll(string(in), max) {
			if len(l.Text) > max || len(l.Text) > l.Len {
				t.Fatalf("line of %d bytes over %d", len(l.Text), max)
			}
			total += l.Len
			if l.EOL {
				total++
			}
		}
		if total != len(in) {
			t.Fatalf("lines cover %d of %d bytes", total, len(in))
		}
	})
}
