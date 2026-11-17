package cksum

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// (moved from status/verbs_test.go)
func TestCksum(t *testing.T) {
	for in, want := range map[string]uint32{"": 4294967295, "hello\n": 3015617425, strings.Repeat("x", 100000): 1627735810} {
		if got, _ := Sum(strings.NewReader(in)); got != want {
			t.Errorf("%d bytes: %d, want %d", len(in), got, want)
		}
	}
}

// (moved from watch/text_test.go)
func TestCksumFile(t *testing.T) {
	// values of GNU cksum
	for _, tt := range []struct {
		data string
		want uint32
	}{{"", 4294967295}, {"hello\n", 3015617425}, {"abc", 1219131554}} {
		p := filepath.Join(t.TempDir(), "f")
		os.WriteFile(p, []byte(tt.data), 0o644)
		if got, err := File(p); err != nil || got != tt.want {
			t.Errorf("cksum(%q) = %d, %v; want %d", tt.data, got, err, tt.want)
		}
	}
}
