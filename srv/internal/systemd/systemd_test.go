package systemd

import (
	"context"
	"errors"
	"slices"
	"strings"
	"testing"

	"tando/srv/internal/run"
)

func TestShow(t *testing.T) {
	var argv []string
	answer := "ActiveState=active\nNRestarts=2\n\nActiveState=failed\nNRestarts=0\nX=a=b\n"
	r := run.Func(func(_ context.Context, c run.Cmd) ([]byte, error) {
		argv = c.Argv
		return []byte(answer), nil
	})
	got, err := Show(context.Background(), r, []string{"tando-a1.service", "tando-b1.service"}, "ActiveState", "NRestarts")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"systemctl", "show", "-p", "ActiveState,NRestarts", "tando-a1.service", "tando-b1.service"}; !slices.Equal(argv, want) {
		t.Errorf("argv %q", argv)
	}
	if len(got) != 2 || got[0]["ActiveState"] != "active" || got[0]["NRestarts"] != "2" ||
		got[1]["ActiveState"] != "failed" || got[1]["X"] != "a=b" {
		t.Errorf("parsed %v", got)
	}
}

func TestShowErrors(t *testing.T) {
	ctx := context.Background()
	units := []string{"a.service", "b.service"}
	short := run.Func(func(context.Context, run.Cmd) ([]byte, error) { return []byte("ActiveState=active\n"), nil })
	if _, err := Show(ctx, short, units, "ActiveState"); err == nil || !strings.Contains(err.Error(), "1 answers for 2") {
		t.Errorf("short answer: %v", err)
	}
	failing := run.Func(func(context.Context, run.Cmd) ([]byte, error) { return nil, errors.New("dbus down") })
	if _, err := Show(ctx, failing, units, "ActiveState"); err == nil {
		t.Error("a failed call was not an error")
	}
	if got, err := Show(ctx, failing, nil, "ActiveState"); got != nil || err != nil {
		t.Errorf("no units: %v, %v (and nothing should run)", got, err)
	}
}

func TestParseShow(t *testing.T) {
	for in, n := range map[string]int{"": 0, "\n\n": 0, "A=1": 1, "A=1\n\nA=2\n": 2, "A=1\n\n\nA=2\n\n": 2} {
		if got := parseShow([]byte(in)); len(got) != n {
			t.Errorf("parseShow(%q): %d blocks, want %d", in, len(got), n)
		}
	}
}
