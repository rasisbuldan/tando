package metrics

import (
	"bytes"
	"os"

	"tando/srv/internal/decimal"
	"tando/srv/internal/out"
	"tando/srv/internal/pgstat"
)

// ReadDB is `read-db <app> <points> <bucket seconds>`: the app's database over the last Points
// buckets, from <app>.db (written by tando-watch, internal/pgstat), and its latest top
// statements. Rows, tab-separated, "-" not known:
//
//	dx <bucket> <now>                 first; "dx none" when the app has no database samples
//	d  <bucket start> <max_connections> <active> <idle> <idle in transaction> <waiting>
//	   <commits/s> <rollbacks/s> <rows returned/s> <fetched/s> <inserted/s> <updated/s> <deleted/s>
//	   <cache hit %> <deadlocks> <temp files> <temp bytes> <conflicts>
//	   <longest transaction s> <longest idle in transaction s> <xid age> <size bytes>
//	   <checkpoints timed> <checkpoints requested> <WAL bytes/s>
//	dl <time> <server_version_num> <max_connections> <active> <idle> <idle in transaction> <waiting>
//	   <longest transaction s> <longest idle in transaction s> <xid age> <wraparound %> <size bytes>
//	   <stats_reset>                  the newest sample (the size: the newest measured)
//	qt <time>                         when the top statements were taken (pg_stat_statements on)
//	q  <calls> <total ms> <mean ms> <rows> <text>   at most 10, most total time first
//
// The sessions are the highest sample of the bucket; the ages their highest; xid age and size
// the bucket's last. Rates and counts come from the differences of consecutive samples at most
// 5 minutes apart whose later one falls in the bucket. A counter that went down or a changed
// stats_reset (pg_stat_reset, a crash on PG <= 14, a new cluster) is a reset: that difference
// is left out, never a negative rate; a bucket without a usable difference has "-".
func (m Metrics) ReadDB(w *out.Writer, a ReadArgs) {
	now := m.Env.Now().Unix()
	from := (now/a.Bucket - a.Points + 1) * a.Bucket
	need := a.Points*a.Bucket/60 + 2
	old, _ := os.ReadFile(pgstat.File(m.Dir, a.Who) + ".1")
	cur, err := os.ReadFile(pgstat.File(m.Dir, a.Who))
	if err != nil && len(old) == 0 {
		w.Row("dx", "none")
		return
	}
	w.Row("dx", decimal.Itoa(a.Bucket), decimal.Itoa(now))
	data := tail(append(tail(old, need), tail(cur, need)...), need)
	data = data[:bytes.LastIndexByte(data, '\n')+1] // (a line still being written is not read)
	var b dbBucket
	var prev, last pgstat.Sample
	var lastSize, lastSizeT int64 = -1, 0
	have := false
	for _, l := range bytes.Split(data, []byte{'\n'}) {
		s, ok := pgstat.Parse(string(l))
		if !ok || (have && s[pgstat.T] <= prev[pgstat.T]) {
			continue
		}
		if s[pgstat.Size] >= 0 {
			lastSize, lastSizeT = s[pgstat.Size], s[pgstat.T]
		}
		if s[pgstat.T] >= from {
			if start := s[pgstat.T] / a.Bucket * a.Bucket; start != b.start {
				b.flush(w)
				b = newDBBucket(start)
			}
			b.add(s, prev, have)
			if s[pgstat.Size] < 0 && lastSize >= 0 && s[pgstat.T]-lastSizeT <= 900 {
				b.size = lastSize // (measured every 5 minutes: the last one stands for the minutes between)
			}
		}
		prev, last, have = s, s, true
	}
	b.flush(w)
	if have {
		wrap := "-"
		if x := last[pgstat.XidAge]; x >= 0 {
			wrap = dec(x*10000/pgstat.Wraparound, 100)
		}
		size := lastSize
		if last[pgstat.T]-lastSizeT > 900 {
			size = -1
		}
		w.Row("dl", decimal.Itoa(last[pgstat.T]), v(last[pgstat.Ver]), v(last[pgstat.MaxConn]), v(last[pgstat.Active]), v(last[pgstat.Idle]),
			v(last[pgstat.IdleTx]), v(last[pgstat.Waiting]), v(last[pgstat.XactAge]), v(last[pgstat.IdleTxAge]), v(last[pgstat.XidAge]),
			wrap, v(size), v(last[pgstat.StatsReset]))
	}
	if t, qs := pgstat.ReadTop(m.Dir, a.Who); len(qs) > 0 {
		w.Row("qt", decimal.Itoa(t))
		for _, q := range qs {
			w.Row("q", decimal.Itoa(q.Calls), decimal.Itoa(q.TotalMs), dec(q.MeanUs/10, 100), decimal.Itoa(q.Rows), q.Text)
		}
	}
}

// dbBucket sums one bucket.
type dbBucket struct {
	start, n              int64
	conn                  [5]int64 // highest max_connections, active, idle, idle in transaction, waiting
	xage, iage, xid, size int64
	dbSecs                int64
	db                    [13]int64 // differences of pgstat.DBCounters
	clSecs                [3]int64  // per cluster counter: seconds covered
	cl                    [3]int64
}

func newDBBucket(start int64) dbBucket {
	return dbBucket{start: start, conn: [5]int64{-1, -1, -1, -1, -1}, xage: -1, iage: -1, xid: -1, size: -1}
}

func (b *dbBucket) add(s, p pgstat.Sample, havePrev bool) {
	b.n++
	for i, c := range []int{pgstat.MaxConn, pgstat.Active, pgstat.Idle, pgstat.IdleTx, pgstat.Waiting} {
		b.conn[i] = max(b.conn[i], s[c])
	}
	b.xage, b.iage = max(b.xage, s[pgstat.XactAge]), max(b.iage, s[pgstat.IdleTxAge])
	if s[pgstat.XidAge] >= 0 {
		b.xid = s[pgstat.XidAge]
	}
	if s[pgstat.Size] >= 0 {
		b.size = s[pgstat.Size]
	}
	dt := s[pgstat.T] - p[pgstat.T]
	if !havePrev || dt <= 0 || dt > 300 {
		return
	}
	// the database's counters reset together: all of them, or none
	okDB := s[pgstat.StatsReset] == p[pgstat.StatsReset]
	for _, c := range pgstat.DBCounters {
		okDB = okDB && s[c] >= 0 && p[c] >= 0 && s[c] >= p[c]
	}
	if okDB {
		b.dbSecs += dt
		for i, c := range pgstat.DBCounters {
			b.db[i] += s[c] - p[c]
		}
	}
	for i, c := range pgstat.ClusterCounters {
		if s[c] >= 0 && p[c] >= 0 && s[c] >= p[c] && s[pgstat.Ver] == p[pgstat.Ver] {
			b.clSecs[i] += dt
			b.cl[i] += s[c] - p[c]
		}
	}
}

func (b *dbBucket) flush(w *out.Writer) {
	if b.n == 0 {
		return
	}
	f := []string{"d", decimal.Itoa(b.start)}
	for _, c := range b.conn {
		f = append(f, v(c))
	}
	// (DBCounters: commit rollback returned fetched inserted updated deleted hit read deadlocks
	// temp_files temp_bytes conflicts)
	for i := 0; i < 7; i++ {
		f = append(f, b.rate(b.db[i], b.dbSecs))
	}
	hit := "-"
	if t := b.db[7] + b.db[8]; b.dbSecs > 0 && t > 0 {
		hit = dec(b.db[7]*10000/t, 100)
	}
	f = append(f, hit)
	for i := 9; i < 13; i++ {
		f = append(f, b.count(b.db[i], b.dbSecs))
	}
	f = append(f, v(b.xage), v(b.iage), v(b.xid), v(b.size), b.count(b.cl[0], b.clSecs[0]), b.count(b.cl[1], b.clSecs[1]), b.rate(b.cl[2], b.clSecs[2]))
	w.Row(f...)
}

// rate: d per second over secs, two decimals; "-" without a usable difference.
func (b *dbBucket) rate(d, secs int64) string {
	if secs <= 0 {
		return "-"
	}
	return dec(d*100/secs, 100)
}

// count: d itself; "-" without a usable difference.
func (b *dbBucket) count(d, secs int64) string {
	if secs <= 0 {
		return "-"
	}
	return decimal.Itoa(d)
}

// v: a value, "-" when not known.
func v(n int64) string {
	if n < 0 {
		return "-"
	}
	return decimal.Itoa(n)
}

// dec: n / div with as many decimals as div has zeros (div 100: "12.05").
func dec(n, div int64) string {
	s := decimal.Itoa(n % div)
	for d := div / 10; d > 1 && n%div < d; d /= 10 {
		s = "0" + s
	}
	return decimal.Itoa(n/div) + "." + s
}
