package daemon

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"tando/srv/daemon/proto"
	"tando/srv/internal/out/outtest"
	"tando/srv/status"
)

// tandod answers through an out.Writer (watch's verbs) and srv/status's sink (status): what it
// sends is clean, so tando-watch and tando-status relay it as it is (proto.AskWatch,
// proto.AskStatus, out.Writer.Relay). Control, C1 and bidi bytes in the watch state, the
// history, an app.conf and a state come out clean; an error message is one line.
func TestAnswersClean(t *testing.T) {
	d, root := testDaemon(t)
	x := outtest.Hostile
	app := filepath.Join(root, "opt/apps/web")
	os.MkdirAll(filepath.Join(app, "releases"), 0o755)
	os.WriteFile(filepath.Join(app, "app.conf"), []byte("port=4100\nrecipe="+x+"\ndomains=a.example.com|"+x+"|off\n"), 0o644)
	os.WriteFile(filepath.Join(app, "state"), []byte("phase="+x+"\ncurrent="+x+"\n"), 0o644)
	os.WriteFile(filepath.Join(root, "lib/watch/state"), []byte("web.health.st=firing\nweb.health.since=100\nweb.health.det="+x+"\n"), 0o644)
	os.WriteFile(filepath.Join(root, "lib/watch/history.tsv"), []byte("1\tfire\tweb\thealth\t"+x+"\n"), 0o644)
	c := status.New(d.Env)
	c.Bus, c.Sys, c.Certs = "", filepath.Join(root, "sys"), filepath.Join(root, "certs")
	c.Statfs = func(string) (uint64, uint64, error) { return 1000, 400, nil }
	c.Net = func() (string, []string) { return "", nil }
	d.Status = c
	ctx := context.Background()
	for _, line := range []string{"status", "status web", "brief", "brief web", "show", "history", "health web"} {
		r, err := proto.Parse(line)
		if err != nil {
			t.Fatal(line, err)
		}
		var b bytes.Buffer
		if err := d.handle(ctx, r, &b); err != nil {
			t.Fatal(line, err)
		}
		if err := outtest.Check(b.Bytes()); err != nil {
			t.Errorf("%s: %v", line, err)
		}
		if line != "health web" && !strings.Contains(b.String(), "[31m") {
			t.Errorf("%s: the hostile text is not shown: %q", line, b.String())
		}
	}
	if h := proto.Header(&status.Error{Msg: "no such app: " + x + "\nsecond line"}, 0); strings.Count(h, "\n") != 1 ||
		strings.ContainsAny(h[:len(h)-1], "\x1b\a\r\x08\x7f\n") {
		t.Errorf("header %q", h)
	}
}
