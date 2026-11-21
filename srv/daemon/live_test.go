package daemon

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"tando/srv/daemon/proto"
	"tando/srv/internal/env"
	"tando/srv/live"
)

func TestLiveVerbs(t *testing.T) {
	d := &Daemon{}
	ctx := context.Background()
	var b bytes.Buffer
	if err := d.handle(ctx, proto.Request{Verb: "live"}, &b); err != errNoLive {
		t.Errorf("live without a fast loop: %v", err)
	}
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "proc"), 0o755)
	os.WriteFile(filepath.Join(dir, "proc", "loadavg"), []byte("0.25 0 0 1/1 1\n"), 0o644)
	e := env.Env{Root: filepath.Join(dir, "root"), Cgroup: dir, Proc: filepath.Join(dir, "proc"),
		Now: func() time.Time { return time.Unix(1_700_000_000, 0) }}
	d.Live = live.New(e, nil)
	d.Live.Statfs = func(string) (uint64, uint64, error) { return 1, 2, nil }
	d.Live.Sample()
	for _, verb := range []string{"live", "ring"} {
		b.Reset()
		if err := d.handle(ctx, proto.Request{Verb: verb}, &b); err != nil || !strings.Contains(b.String(), "host\t1700000000\t0.25\t") {
			t.Errorf("%s: %v %q", verb, err, b.String())
		}
	}
	if _, err := proto.Parse("live a1"); err != nil {
		t.Errorf("live [app] is not a request: %v", err)
	}
}
