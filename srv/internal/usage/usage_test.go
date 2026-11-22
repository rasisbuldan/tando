package usage

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestAppendReadCursor(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "usage")
	now := time.Unix(1_800_000_000, 0)
	if err := Append(dir, now, []Row{{T: 1, App: "a", Boot: "b"}, {T: 1, App: "b", Boot: "b"}}); err != nil {
		t.Fatal(err)
	}
	// a row cut by a crash: skipped, and the next rows still start on their own line
	f, _ := os.OpenFile(filepath.Join(dir, "seg-0000000000000001.tsv"), os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString("3\t2\tb\ta")
	f.Close()
	if err := Append(dir, now, []Row{{T: 2, App: "a", Boot: "b"}}); err != nil {
		t.Fatal(err)
	}
	p, err := Read(dir, 0, 10, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Rows) != 3 || p.Rows[2].Seq != 3 || p.Rows[2].T != 2 || p.Next != 3 || p.Gap || p.More || p.Oldest != 1 {
		t.Fatalf("read: %+v", p)
	}
	p, _ = Read(dir, 0, 2, "")
	if len(p.Rows) != 2 || !p.More || p.Next != 2 {
		t.Errorf("limit: %+v", p)
	}
	p, _ = Read(dir, 1, 10, "a")
	if len(p.Rows) != 1 || p.Rows[0].Seq != 3 || p.Next != 3 {
		t.Errorf("app filter: %+v", p)
	}
	p, _ = Read(dir, 3, 10, "")
	if len(p.Rows) != 0 || p.Next != 3 {
		t.Errorf("nothing new: %+v", p)
	}
}

func TestSegmentsAndPrune(t *testing.T) {
	dir := t.TempDir()
	now := time.Unix(1_800_000_000, 0)
	big := strings.Repeat("x", 200)
	for i := 0; i < 3; i++ {
		rows := make([]Row, 20000)
		for j := range rows {
			rows[j] = Row{T: 1, App: big, Boot: "b"}
		}
		if err := Append(dir, now, rows); err != nil {
			t.Fatal(err)
		}
	}
	segs, _ := segments(dir)
	if len(segs) != 2 || segs[1] != "seg-0000000000040001.tsv" {
		t.Fatalf("segments: %v", segs)
	}
	p, _ := Read(dir, 40000, 5, "")
	if len(p.Rows) != 5 || p.Rows[0].Seq != 40001 {
		t.Errorf("read in the second segment: %+v", p.Rows[0])
	}
	// the old segment ages out; a reader behind it learns of the gap; seq goes on
	old := now.Add(-Keep - time.Hour)
	os.Chtimes(filepath.Join(dir, segs[0]), old, old)
	if err := Append(dir, now, []Row{{T: 2, App: "a", Boot: "b"}}); err != nil {
		t.Fatal(err)
	}
	p, _ = Read(dir, 10, 1, "")
	if !p.Gap || p.Oldest != 40001 || p.Rows[0].Seq != 40001 {
		t.Errorf("after prune: gap %v oldest %d rows %+v", p.Gap, p.Oldest, p.Rows)
	}
	p, _ = Read(dir, 60000, 5, "")
	if len(p.Rows) != 1 || p.Rows[0].Seq != 60001 {
		t.Errorf("seq after prune: %+v", p.Rows)
	}
}

func TestAwake(t *testing.T) {
	const s = 1_000_000
	for _, c := range []struct {
		name   string
		ae, ie int64
		up     bool
		want   int64
	}{
		{"up all along", 10 * s, 0, true, 60},
		{"woke in it", 130 * s, 0, true, 30},
		{"slept in it", 10 * s, 120 * s, false, 20},
		{"woke and slept in it", 110 * s, 150 * s, false, 40},
		{"asleep all along", 10 * s, 50 * s, false, 0},
		{"never up", 0, 0, false, 0},
		{"failed start", 140 * s, 130 * s, false, 0},
	} {
		if got := Awake(c.ae, c.ie, c.up, 100*s, 160*s) / s; got != c.want {
			t.Errorf("%s: %d, want %d", c.name, got, c.want)
		}
	}
}

func TestCaps(t *testing.T) {
	c := map[string]string{"memory": "1G", "worker.a": "x", "worker.b": "y", "worker.b.memory": "64M", "worker.x.y": "z"}
	if w, k := Caps(c); w != 1024 || k != 1024+64 {
		t.Errorf("caps %d %d", w, k)
	}
	if w, k := Caps(map[string]string{}); w != 256 || k != 0 {
		t.Errorf("default %d %d", w, k)
	}
	// admission as mem_caps_mb -a: idle_stop counts 2 MB + idle_awake %
	if a := Admitted(map[string]string{"memory": "512M", "idle_stop": "5m"}, 20); a != 2+103 {
		t.Errorf("admitted %d", a)
	}
	if a := Admitted(map[string]string{"memory": "512M", "idle_stop": "5m", "recipe": "container"}, 20); a != 512 {
		t.Errorf("container %d", a)
	}
	if MB("65536K", 1) != 64 || MB("x", 7) != 7 || MB("12", 7) != 7 {
		t.Error("MB")
	}
}
