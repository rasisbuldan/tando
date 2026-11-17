package metrics

import (
	"strings"
	"testing"

	"tando/srv/internal/out/outtest"
)

// tando-metrics prints only through its out.Writer: a damaged samples file with control, C1 and
// bidi bytes in a field gives clean rows (srv/README.md, Output).
func TestOutputClean(t *testing.T) {
	h := newHost(t)
	h.now = 1_800_000_300
	h.write("lib/metrics/web.tsv", "1800000060\t2000\t30000000\t1\t"+outtest.Hostile+"\n"+
		"1800000120\t3000\t1200000\t2\t"+outtest.Hostile+"\t"+outtest.Hostile+"\n")
	o := h.readOut("web", "5", "60")
	if err := outtest.Check([]byte(o)); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(o, "[2Jevilx") || strings.Count(o, "\n") != 3 {
		t.Errorf("rows lost: %q", o)
	}
}
