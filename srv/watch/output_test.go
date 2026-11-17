package watch

import (
	"context"
	"strings"
	"testing"

	"tando/srv/internal/out"
	"tando/srv/internal/out/outtest"
)

// Every verb of tando-watch prints through its out.Writer: control, C1 and bidi bytes in the
// state, the history, a notifier's error, the settings and the incidents come out clean
// (srv/README.md, Output). tandod answers the same verbs with the same code; tando-watch relays
// that answer as it is (proto.AskWatch, out.Writer.Relay).
func TestOutputClean(t *testing.T) {
	f := newFakeHost(t)
	f.app("hog")
	w := f.watch()
	h := outtest.Hostile
	f.write("lib/watch/state", "hog.health.st=firing\nhog.health.since=100\nhog.health.det="+h+"\nhog.health.ns=firing\n"+
		"_host.disk.st=pending\n_host.disk.n=1\n_host.disk.det="+h+"\n_nf.hook.fails=2\n_nf.hook.err="+h+"\n_nf.hook.since=1\n")
	f.write("lib/watch/history.tsv", "1\tfire\thog\thealth\t"+h+"\n2\tresolve\t"+h+"\tdisk\t"+h+"\n")
	f.write("lib/watch/incidents/hog.tsv", "1\t2\t"+h+"\n")
	f.notifier("hook", "type=webhook\nurl=https://"+h+"/x\n")
	f.write("opt/alerts.conf", "mem_pct="+h+"\nname="+h+"\n")
	ctx := context.Background()
	for name, fn := range map[string]func(o *out.Writer) error{
		"show":    func(o *out.Writer) error { return w.Show(ctx, o, nil) },
		"brief":   func(o *out.Writer) error { w.Brief(o, nil); return nil },
		"history": func(o *out.Writer) error { return w.History(o, nil) },
		"health":  func(o *out.Writer) error { return w.Health(o, nil) },
		"doctor":  func(o *out.Writer) error { w.Doctor(ctx, o); return nil },
	} {
		o, _ := do(fn)
		if err := outtest.Check([]byte(o)); err != nil {
			t.Errorf("%s: %v", name, err)
		}
		if name != "doctor" && name != "health" && !strings.Contains(o, "evil") {
			t.Errorf("%s: the hostile text is not shown at all:\n%s", name, o)
		}
	}
}
