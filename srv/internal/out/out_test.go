package out

import (
	"bytes"
	"errors"
	"testing"
)

func TestClean(t *testing.T) {
	tests := []struct{ in, want string }{
		{"hello-1 42", "hello-1 42"},
		{"", ""},
		{"a\tb\nc\rd", "a?b?c?d"},
		{"esc \x1b[2J del \x7f", "esc ?[2J del ?"},
		{"utf-8 c1 \u0085 \u009b", "utf-8 c1 ? ?"},
		{"lone c1 \x9b[2J", "lone c1 ?[2J"},
		{"latin-1 \xe9 kept", "latin-1 \xe9 kept"},
		{"é ok", "é ok"},
		{"bidi ‮evil‬ ⁦x⁩ ‎؜.", "bidi evil x ."},
	}
	for _, tt := range tests {
		if got := Clean(tt.in); got != tt.want {
			t.Errorf("Clean(%q) = %q, want %q", tt.in, got, tt.want)
		}
	}
}

func TestWriter(t *testing.T) {
	var b bytes.Buffer
	w := New(&b)
	w.Row("m", "60", "", "a\tb")
	w.KV("version", "1.2.3")
	w.KV("detail", "x\ny")
	w.KV("empty", "")
	if err := w.Flush(); err != nil {
		t.Fatal(err)
	}
	want := "m\t60\t-\ta?b\nversion=1.2.3\ndetail=x?y\nempty=\n"
	if b.String() != want {
		t.Errorf("got %q, want %q", b.String(), want)
	}
}

type failWriter struct{}

func (failWriter) Write([]byte) (int, error) { return 0, errors.New("closed") }

func TestWriterError(t *testing.T) {
	w := New(failWriter{})
	w.Row("x")
	if err := w.Flush(); err == nil {
		t.Error("Flush hid a write error")
	}
}
