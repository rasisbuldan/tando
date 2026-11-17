package errscan

import (
	"fmt"
	"strings"
	"testing"
)

// an app spraying hundreds of distinct new messages does not push out the groups already known:
// the next time a known error is logged it is counted, not reported as new again
func TestSprayDoesNotEvictKnownGroups(t *testing.T) {
	const t1 = 1794589200
	var known strings.Builder
	for i := range MaxGroups {
		fmt.Fprintf(&known, "k%07d\t1\t%d\t%d\tr\tline\tL\tfp\tknown %d\t\n", i, t1-86400, t1-86400, i)
	}
	tb := &Table{Now: t1}
	tb.Load([]byte(known.String()))
	for i := range 3 * MaxGroups {
		tb.Add(Event{T0: t1 - 10, ID: fmt.Sprintf("s%07d", i), Kind: "line", Label: "L", Fingerprint: "f", Title: "spray"})
	}
	r := tb.Result()
	if strings.Contains(string(r.Data), "\ts") || strings.Count(string(r.Data), "\n") != MaxGroups {
		t.Fatalf("known groups pushed out")
	}
	tb = &Table{Now: t1 + 60}
	tb.Load(r.Data)
	tb.Add(Event{T0: t1 + 30, ID: "k0000007", Kind: "line", Label: "L", Fingerprint: "fp", Title: "known 7"})
	if r := tb.Result(); len(r.New) != 0 || len(r.Counts) != 1 {
		t.Fatalf("a known group reported as new: %+v", r.New)
	}
	// groups not seen for KeepDays days give way, least recently seen first
	var old strings.Builder
	for i := range MaxGroups {
		fmt.Fprintf(&old, "o%07d\t1\t%d\t%d\tr\tline\tL\tfp\told\t\n", i, t1-9*86400, t1-9*86400+int64(i))
	}
	tb = &Table{Now: t1}
	tb.Load([]byte(old.String()))
	tb.Add(Event{T0: t1, ID: "n0000001", Kind: "line", Label: "L", Fingerprint: "f", Title: "new"})
	if r := tb.Result(); len(r.Dropped) != 1 || r.Dropped[0] != "o0000000" || len(r.New) != 1 {
		t.Fatalf("dropped %v new %v", r.Dropped, r.New)
	}
}

// groups.tsv's cursor line (see logs.writeCursor) is not a group to any reader
func TestCursorLineIsNoGroup(t *testing.T) {
	data := []byte("k1\t1\t5\t1794589000\tr\tline\tL\tfp\tt\t\ncursor\ts=1;i=2;t=3\n")
	if w := Window(data, 1794580000, 10); len(w) != 1 {
		t.Fatalf("%q", w)
	}
	tb := &Table{Now: 1794589200}
	tb.Load(data)
	if r := tb.Result(); string(r.Data) != "k1\t1\t5\t1794589000\tr\tline\tL\tfp\tt\t\n" {
		t.Fatalf("%q", r.Data)
	}
}
