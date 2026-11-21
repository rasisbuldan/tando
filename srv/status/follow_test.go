package status

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"tando/srv/internal/env"
)

const fullRows = "host\tbox\t2\t0.10\t2000\t1000\t9000\t3000\t500\n" + "server\t1800000000\t0.3.0\n" +
	"app\ta1\tactive\t3000\tr1\tok\t100\t0\t5\t1\t60\tlink\tnode\toff\t\t\t1\t2\t3\t4\t-\t1,2\t-\t1024\t256\t-\t12\n" +
	"app\tst\tactive\t-\tr1\tok\t0\t0\t0\t0\t0\tlink\tstatic\toff\t\t\t1\t2\t3\t4\t-\t-\t-\t1024\t256\t-\t-\n" +
	"app\tsp\tstopped\t3001\tr1\tok\t0\t0\t0\t0\t0\tlink\tnode\toff\t\t\t1\t2\t3\t4\t-\t-\t-\t1024\t256\t-\t-\n" +
	"alert\ta1\tmem\tok\n"

const liveRows = "lhost\t1800000005\t1.50\t1500\t2000\t250\t3500\t9000\n" +
	"lapp\ta1\t1800000005\tactive\trunning\t3\t77\t4096\t420\t9\t6000\n" +
	"lapp\tst\t1800000005\tinactive\tdead\t0\t0\t0\t-\t0\n" +
	"lapp\tsp\t1800000005\tactive\trunning\t0\t1\t50\t1\t1\n"

func TestPatch(t *testing.T) {
	got := string(Patch([]byte(fullRows), []byte(liveRows), 5))
	want := "host\tbox\t2\t1.50\t2000\t1500\t9000\t3500\t505\n" + "server\t1800000005\t0.3.0\n" +
		"app\ta1\tactive\t3000\tr1\tok\t4096\t0\t6000000\t3\t65\tlink\tnode\toff\t\t\t1\t2\t3\t4\t-\t1,2\t-\t1024\t256\t420\t12\n" +
		// a static site and an app tando stopped keep status's state word
		"app\tst\tactive\t-\tr1\tok\t0\t0\t0\t0\t0\tlink\tstatic\toff\t\t\t1\t2\t3\t4\t-\t-\t-\t1024\t256\t-\t-\n" +
		"app\tsp\tstopped\t3001\tr1\tok\t50\t0\t0\t0\t0\tlink\tnode\toff\t\t\t1\t2\t3\t4\t-\t-\t-\t1024\t256\t1\t-\n" +
		"alert\ta1\tmem\tok\n"
	if got != want {
		t.Errorf("patched:\n%s\nwant\n%s", got, want)
	}
	// it died between two whole statuses: failed at once, no uptime
	died := strings.Replace(liveRows, "\tactive\trunning\t3\t77", "\tfailed\tfailed\t3\t0", 1)
	got = string(Patch([]byte(fullRows), []byte(died), 5))
	if !strings.Contains(got, "app\ta1\tfailed\t3000\tr1\tok\t4096\t0\t6000000\t3\t0\t") {
		t.Errorf("a dead app:\n%s", got)
	}
	if got := Patch([]byte(fullRows), nil, 5); string(got) != fullRows {
		t.Errorf("without live rows the status changed:\n%s", got)
	}
}

// frames: a writer that takes n frames and then fails (the reader went away).
type frames struct {
	bytes.Buffer
	n int
}

func (f *frames) Write(p []byte) (int, error) {
	if f.n == 0 {
		return 0, errors.New("closed")
	}
	f.n--
	return f.Buffer.Write(p)
}

func TestFollow(t *testing.T) {
	now := int64(1_800_000_000)
	c := &Collector{Env: env.Env{EUID: 0, Now: func() time.Time { return time.Unix(now, 0) }}}
	fulls, lives := 0, 0
	remote := func(context.Context, string) ([]byte, bool) { fulls++; return []byte(fullRows), true }
	lv := func(context.Context, string) ([]byte, bool) { lives++; now += 5; return []byte(liveRows), true }
	w := &frames{n: 14}
	if err := c.Follow(context.Background(), w, "", remote, lv, time.Millisecond, 60*time.Second); err != nil {
		t.Fatal(err)
	}
	out := w.String()
	if n := strings.Count(out, "@frame "); n != 14 || strings.Count(out, "@end\n") != 14 || lives != 15 {
		t.Fatalf("%d frames, %d live reads:\n%s", n, lives, out)
	}
	// the whole status once a minute (frames 5 s apart), the live rows in every frame
	if fulls != 2 {
		t.Errorf("status collected %d times in 14 frames 5 s apart, want 2", fulls)
	}
	// a unit that changes state: the whole status at once (tando's state word, the release)
	fulls, lives = 0, 0
	flip := func(context.Context, string) ([]byte, bool) {
		lives++
		now += 5
		if lives == 3 {
			return []byte(strings.Replace(liveRows, "active\trunning\t3", "failed\tfailed\t3", 1)), true
		}
		return []byte(liveRows), true
	}
	if err := c.Follow(context.Background(), &frames{n: 5}, "", remote, flip, time.Millisecond, 60*time.Second); err != nil {
		t.Fatal(err)
	}
	if fulls != 3 { // the first frame, the failure, and back to active
		t.Errorf("status collected %d times with a state change in between, want 3", fulls)
	}
	if strings.Count(out, "lapp\ta1\t") != 14 || !strings.HasPrefix(out, "@frame 1800000000\nhost\tbox\t2\t1.50\t") {
		t.Errorf("frames:\n%s", out[:300])
	}

	// no fast loop (an older tandod, cgroup v1): nothing written, ErrNoLive (the client polls)
	var b bytes.Buffer
	none := func(context.Context, string) ([]byte, bool) { return nil, false }
	if err := c.Follow(context.Background(), &b, "", remote, none, time.Millisecond, time.Minute); err != ErrNoLive || b.Len() != 0 {
		t.Errorf("without live rows: %v, wrote %q", err, b.String())
	}
}
