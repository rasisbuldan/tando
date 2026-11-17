package decimal

import (
	"strconv"
	"testing"
)

func TestParse(t *testing.T) {
	for _, tt := range []struct {
		s   string
		max int
		n   int64
		ok  bool
	}{
		{"0", 18, 0, true}, {"08", 18, 8, true}, {"010", 18, 10, true}, {"123", 3, 123, true},
		{"1234", 3, 0, false}, {"", 18, 0, false}, {"-1", 18, 0, false}, {"+1", 18, 0, false},
		{" 1", 18, 0, false}, {"1 ", 18, 0, false}, {"1a", 18, 0, false}, {"0x10", 18, 0, false},
		{"999999999999999999", 18, 999999999999999999, true}, {"1000000000000000000", 18, 0, false},
		{"١", 18, 0, false}, // (an Arabic-Indic digit is not a digit here)
	} {
		if n, ok := Parse(tt.s, tt.max); n != tt.n || ok != tt.ok {
			t.Errorf("Parse(%q, %d) = %d, %v; want %d, %v", tt.s, tt.max, n, ok, tt.n, tt.ok)
		}
	}
}

func TestIsDigits(t *testing.T) {
	for s, want := range map[string]bool{"0": true, "0123456789": true, "": false, "1.0": false, "-1": false,
		"12345678901234567890123": true} {
		if IsDigits(s) != want {
			t.Errorf("IsDigits(%q) != %v", s, want)
		}
	}
}

func FuzzParse(f *testing.F) {
	for _, s := range []string{"0", "08", "", "-1", "999999999999999999", "1e3"} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, s string) {
		n, ok := Parse(s, 18)
		v, err := strconv.ParseUint(s, 10, 63)
		want := err == nil && len(s) <= 18 && s != "" && s[0] != '+'
		if ok != want || (ok && n != int64(v)) {
			t.Fatalf("Parse(%q) = %d, %v; strconv: %d, %v", s, n, ok, v, err)
		}
		if ok != (IsDigits(s) && len(s) <= 18) {
			t.Fatalf("Parse and IsDigits disagree on %q", s)
		}
		if ok && Itoa(n) != strconv.FormatInt(n, 10) {
			t.Fatal("Itoa")
		}
	})
}
