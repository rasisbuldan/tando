package kvfile

import (
	"maps"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"tando/srv/internal/atomicfile"
)

func TestParse(t *testing.T) {
	tests := []struct {
		name, in string
		want     map[string]string
	}{
		{"plain", "port=4100\nrecipe=node\n", map[string]string{"port": "4100", "recipe": "node"}},
		{"first = splits", "start=node a=b\n", map[string]string{"start": "node a=b"}},
		{"trailing = kept", "token=abc==\n", map[string]string{"token": "abc=="}},
		{"empty value", "current=\n", map[string]string{"current": ""}},
		{"skipped lines", "no equals\n=x\n# a comment with key=value\n\n", map[string]string{}},
		{"last duplicate wins", "a=1\na=2\n", map[string]string{"a": "2"}},
		{"no final newline", "a=1\nb=2", map[string]string{"a": "1", "b": "2"}},
		{"spaces are data", " a = 1 \n", map[string]string{" a ": " 1 "}},
		{"crlf is data", "a=1\r\n", map[string]string{"a": "1\r"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := Parse(strings.NewReader(tt.in))
			if err != nil {
				t.Fatal(err)
			}
			if !maps.Equal(got, tt.want) {
				t.Errorf("got %q, want %q", got, tt.want)
			}
		})
	}
}

func TestLoadMissing(t *testing.T) {
	m, err := Load(filepath.Join(t.TempDir(), "state"))
	if err != nil || len(m) != 0 {
		t.Fatalf("Load of a missing file = %v, %v", m, err)
	}
}

func TestSaveRoundTrip(t *testing.T) {
	p := filepath.Join(t.TempDir(), "state")
	m := map[string]string{"phase": "idle", "current": "20261114-170102", "z": "", "tok": "a=="}
	for i, wantChanged := range []bool{true, false} {
		changed, err := Save(p, m, atomicfile.Mode(0o640))
		if err != nil || changed != wantChanged {
			t.Fatalf("save %d: changed=%v err=%v", i, changed, err)
		}
	}
	raw, _ := os.ReadFile(p)
	if want := "current=20261114-170102\nphase=idle\ntok=a==\nz=\n"; string(raw) != want {
		t.Errorf("file %q, want %q (sorted)", raw, want)
	}
	if fi, _ := os.Stat(p); fi.Mode().Perm() != 0o640 {
		t.Errorf("mode %v", fi.Mode().Perm())
	}
	back, err := Load(p)
	if err != nil || !maps.Equal(back, m) {
		t.Errorf("read back %q, %v", back, err)
	}
}

func TestFormatRefuses(t *testing.T) {
	for _, m := range []map[string]string{{"a\nb": "1"}, {"a=b": "1"}, {"": "1"}, {"a": "1\nb=2"}} {
		if _, err := Format(m); err == nil {
			t.Errorf("Format(%q) did not refuse", m)
		}
	}
}
