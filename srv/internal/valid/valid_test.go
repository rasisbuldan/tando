package valid

import (
	"math"
	"testing"
)

func TestApp(t *testing.T) {
	for s, want := range map[string]bool{
		"hello": true, "a1": true, "my-app-2": true, "abcdefghijklmnopqrstuvwxyz": true,
		"a": false, "abcdefghijklmnopqrstuvwxyz0": false, "1app": false, "-app": false, "App": false,
		"../x": false, "a b": false, "a_b": false, "": false, "hello\n": false, "héllo": false,
	} {
		if got := App(s); got != want {
			t.Errorf("App(%q) = %v", s, got)
		}
	}
}

func TestID(t *testing.T) {
	for s, want := range map[string]bool{
		"20261114-170102": true, "20261114-170102-2": true, "20261114-170102-123": true,
		"20261114-170102-1234": false, "2026111-170102": false, "20261114170102": false, "": false,
	} {
		if got := ID(s); got != want {
			t.Errorf("ID(%q) = %v", s, got)
		}
	}
}

func TestUint(t *testing.T) {
	tests := []struct {
		s      string
		lo, hi int64
		want   int64
		ok     bool
	}{
		{"60", 60, 86400, 60, true},
		{"08", 1, 10, 8, true},
		{"0060", 60, 86400, 60, true},
		{"59", 60, 86400, 59, false},
		{"86401", 60, 86400, 86401, false},
		{"", 0, 10, 0, false},
		{"-1", -5, 10, 0, false},
		{"+1", 0, 10, 0, false},
		{"1 ", 0, 10, 0, false},
		{"1e3", 0, 9999, 0, false},
		{"999999999999999999", 0, math.MaxInt64, 999999999999999999, true},
		{"9999999999999999999", 0, math.MaxInt64, 0, false},
	}
	for _, tt := range tests {
		got, ok := Uint(tt.s, tt.lo, tt.hi)
		if ok != tt.ok || (ok && got != tt.want) {
			t.Errorf("Uint(%q, %d, %d) = %d, %v; want %d, %v", tt.s, tt.lo, tt.hi, got, ok, tt.want, tt.ok)
		}
	}
}
