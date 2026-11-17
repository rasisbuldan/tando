package outtest

import (
	"testing"

	"tando/srv/internal/out"
)

func TestCheck(t *testing.T) {
	if Check([]byte(Hostile)) == nil {
		t.Fatal("Hostile passes Check")
	}
	for _, s := range []string{"\x1b", "\a", "\r", "\x7f", "\u0085", "\x9b", "‮", "⁦", "‏", "؜"} {
		if Check([]byte("ok "+s)) == nil {
			t.Errorf("%q passes", s)
		}
	}
	if err := Check([]byte(out.Clean(Hostile) + "\tlatin-1 \xe9\n")); err != nil {
		t.Errorf("cleaned: %v", err)
	}
}
