package metrics

import (
	"bytes"
	"strings"
	"testing"

	"tando/srv/internal/out"
	"tando/srv/internal/pgstat"
)

func (h *host) readDB(args ...string) string {
	h.t.Helper()
	a, err := ParseReadArgs(args)
	if err != nil {
		h.t.Fatal(err)
	}
	var b bytes.Buffer
	w := out.New(&b)
	h.m.ReadDB(w, a)
	if err := w.Flush(); err != nil {
		h.t.Fatal(err)
	}
	return b.String()
}

// dbSample: a line at t with commits c, blocks hit/read, deadlocks d, stats_reset r, WAL bytes wal.
func dbSample(t, c, hit, read, d, r, wal int64, size int64) string {
	s := pgstat.Empty()
	s[pgstat.T], s[pgstat.Ver], s[pgstat.MaxConn] = t, 160004, 20
	s[pgstat.Active], s[pgstat.Idle], s[pgstat.IdleTx], s[pgstat.Waiting] = 1, 3, 0, 0
	for _, k := range pgstat.DBCounters {
		s[k] = 0
	}
	s[pgstat.Commit], s[pgstat.Rollback], s[pgstat.BlksHit], s[pgstat.BlksRead], s[pgstat.Deadlocks] = c, 1, hit, read, d
	s[pgstat.StatsReset], s[pgstat.XactAge], s[pgstat.IdleTxAge], s[pgstat.XidAge], s[pgstat.Size] = r, 2, 0, 536870912, size
	s[pgstat.CkptTimed], s[pgstat.CkptReq], s[pgstat.WalBytes] = 10, 1, wal
	return s.Line() + "\n"
}

func TestReadDBRatesResetsAndGaps(t *testing.T) {
	h := newHost(t)
	h.now = 1_800_000_300 // five one-minute buckets from 1800000060
	h.write("lib/metrics/web.db", ""+
		dbSample(1_800_000_000, 1000, 900, 100, 0, 5, 6000, 4096)+ // before the window: the base of the next
		dbSample(1_800_000_060, 1600, 1890, 110, 1, 5, 12000, -1)+ // 10 commits/s, 99% hit, 1 deadlock, 100 WAL B/s
		dbSample(1_800_000_120, 40, 10, 0, 0, 1_800_000_100, 0, -1)+ // pg_stat_reset + a new cluster: a gap
		dbSample(1_800_000_180, 160, 20, 0, 0, 1_800_000_100, 600, -1)+ // 2 commits/s again
		"garbage\n"+
		dbSample(1_800_000_240, 100, 30, 0, 0, 1_800_000_100, 900, -1)+ // commits down without a new stats_reset (a crash, PG <= 14): a gap
		dbSample(1_800_000_290, 9, 9, 9, 9, 9, 9, 9)[:20]) // still being written: not read
	got := h.readDB("web", "5", "60")
	want := "dx\t60\t1800000300\n" +
		"d\t1800000060\t20\t1\t3\t0\t0\t10.00\t0.00\t0.00\t0.00\t0.00\t0.00\t0.00\t99.00\t1\t0\t0\t0\t2\t0\t536870912\t4096\t0\t0\t100.00\n" +
		"d\t1800000120\t20\t1\t3\t0\t0\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t2\t0\t536870912\t4096\t0\t0\t-\n" +
		"d\t1800000180\t20\t1\t3\t0\t0\t2.00\t0.00\t0.00\t0.00\t0.00\t0.00\t0.00\t100.00\t0\t0\t0\t0\t2\t0\t536870912\t4096\t0\t0\t10.00\n" +
		"d\t1800000240\t20\t1\t3\t0\t0\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t2\t0\t536870912\t4096\t0\t0\t5.00\n" +
		"dl\t1800000240\t160004\t20\t1\t3\t0\t0\t2\t0\t536870912\t25.00\t4096\t1800000100\n"
	if got != want {
		t.Errorf("got\n%s\nwant\n%s", got, want)
	}
}

func TestReadDBSizeGoesStaleAndNoFile(t *testing.T) {
	h := newHost(t)
	h.now = 1_800_003_600
	if got := h.readDB("web", "60", "60"); got != "dx\tnone\n" {
		t.Errorf("no file: %q", got)
	}
	h.write("lib/metrics/web.db", dbSample(1_800_000_000, 1, 1, 1, 0, 5, 1, 4096)+dbSample(1_800_003_000, 1, 1, 1, 0, 5, 1, -1))
	got := h.readDB("web", "60", "60")
	if !strings.HasSuffix(got, "\t536870912\t25.00\t-\t5\n") || strings.Contains(got, "4096") {
		t.Errorf("a size measured 50 minutes before is not the size now: %q", got)
	}
}

func TestReadDBTop(t *testing.T) {
	h := newHost(t)
	h.now = 1_800_000_300
	h.write("lib/metrics/web.db", dbSample(1_800_000_240, 1, 1, 1, 0, 5, 1, 1))
	if err := pgstat.WriteTop(h.m.Dir, "web", 1_800_000_240, []pgstat.Query{
		{Calls: 120, TotalMs: 5300, MeanUs: 44166, Rows: 360, Text: "SELECT *\n\tFROM orders WHERE id = $1"},
		{Calls: 1, TotalMs: 2, MeanUs: 5, Rows: 0, Text: strings.Repeat("x", 900)},
	}); err != nil {
		t.Fatal(err)
	}
	got := h.readDB("web", "5", "60")
	if !strings.Contains(got, "\nqt\t1800000240\nq\t120\t5300\t44.16\t360\tSELECT * FROM orders WHERE id = $1\nq\t1\t2\t0.00\t0\t"+strings.Repeat("x", 500)+"\n") {
		t.Errorf("top: %q", got)
	}
}

// A reset followed by enough work to pass the old values within the minute: stats_reset says so.
func TestReadDBResetWithHigherCounters(t *testing.T) {
	h := newHost(t)
	h.now = 1_800_000_100
	h.write("lib/metrics/web.db", dbSample(1_800_000_000, 100, 10, 1, 0, 5, 1, 1)+dbSample(1_800_000_060, 9000, 900, 90, 3, 1_800_000_030, 2, 1))
	if got := h.readDB("web", "1", "60"); !strings.HasPrefix(got, "dx\t60\t1800000100\nd\t1800000060\t20\t1\t3\t0\t0\t-\t-\t-\t-\t-\t-\t-\t-\t-\t") {
		t.Errorf("a new stats_reset counted as work: %q", got)
	}
}
