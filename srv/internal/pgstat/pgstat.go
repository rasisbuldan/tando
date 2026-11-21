// Package pgstat is the format of the per-minute PostgreSQL samples of an app's database: what
// srv/watch writes from its one psql a minute (check_postgres.go, check_dbstats.go) and srv/metrics
// reads (`tando-metrics read-db`). Both domain packages need it, so it lives here.
//
// Files, in the metrics directory (/var/lib/tando/metrics, root 700), per app with a database:
//
//	<app>.db, <app>.db.1   one line a minute: the Cols below, tab-separated, "-" not known.
//	                       Counters are PostgreSQL's raw ones (since its stats_reset); a reader
//	                       takes differences, and a counter that went down (a reset, a crash on
//	                       PG <= 14) or a changed stats_reset is a gap, never a negative rate.
//	                       Becomes .db.1 past rotateAt bytes (the old .1 goes): about 7 days.
//	<app>.dbtop            only with pg_stat_statements on (tando host setup --pg-stat-statements):
//	                       the latest top 10 normalized statements of its database, rewritten each
//	                       minute, never kept as history. 0600 like every file here.
//
// App names are [a-z0-9-] without dots, so <app>.db can never be another app's <app>.tsv.
// Columns are only ever added at the end; a reader takes the fields it knows.
//
// Layer: internal: the standard library and internal/atomicfile only; never a domain package.
package pgstat

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"tando/srv/internal/atomicfile"
)

// The columns of a line of <app>.db, in order.
const (
	T          = iota // unix time of the sample
	Ver               // server_version_num (170002)
	MaxConn           // max_connections
	Active            // client sessions of the database: active
	Idle              //   idle
	IdleTx            //   idle in transaction (aborted ones too)
	Waiting           //   waiting for a lock (wait_event_type Lock)
	Commit            // pg_stat_database counters, raw
	Rollback          //
	Returned          //
	Fetched           //
	Inserted          //
	Updated           //
	Deleted           //
	BlksHit           //
	BlksRead          //
	Deadlocks         //
	TempFiles         //
	TempBytes         //
	Conflicts         //
	StatsReset        // stats_reset as unix time (0: never reset)
	XactAge           // seconds the oldest open transaction has run (not pg_dump's, not tando-watch's)
	IdleTxAge         // seconds the longest idle-in-transaction session has been idle
	XidAge            // age(datfrozenxid): transaction IDs used towards wraparound (2^31)
	Size              // pg_database_size, when measured that minute ("-" otherwise)
	CkptTimed         // the cluster's checkpoints: timed (pg_stat_bgwriter <= 16, pg_stat_checkpointer 17+)
	CkptReq           //   requested
	WalBytes          // the cluster's WAL bytes (pg_stat_wal, PG 14+)
	NCols
)

// Counters are the columns a reader takes differences of (the database's, then the cluster's).
var (
	DBCounters      = []int{Commit, Rollback, Returned, Fetched, Inserted, Updated, Deleted, BlksHit, BlksRead, Deadlocks, TempFiles, TempBytes, Conflicts}
	ClusterCounters = []int{CkptTimed, CkptReq, WalBytes}
)

// Wraparound is where PostgreSQL stops: 2^31 transaction IDs.
const Wraparound = int64(1) << 31

const (
	fileMode = 0o600
	rotateAt = 1200 << 10 // bytes of <app>.db before it becomes .db.1 (~240 B a line: ~3.5 days)
)

// Sample is one line: a value per column, -1 where not known.
type Sample [NCols]int64

// Empty is a sample with nothing known.
func Empty() Sample {
	var s Sample
	for i := range s {
		s[i] = -1
	}
	return s
}

// Line renders the sample ("-" for not known), without the newline.
func (s Sample) Line() string {
	f := make([]string, NCols)
	for i, v := range s {
		if v < 0 {
			f[i] = "-"
		} else {
			f[i] = strconv.FormatInt(v, 10)
		}
	}
	return strings.Join(f, "\t")
}

// Parse reads a line; false when its time is not a number (a damaged line). Missing columns
// (an older writer) and anything not a number are not known.
func Parse(line string) (Sample, bool) {
	s := Empty()
	for i, f := range strings.Split(line, "\t") {
		if i >= NCols {
			break
		}
		if n, err := strconv.ParseInt(f, 10, 64); err == nil && n >= 0 {
			s[i] = n
		}
	}
	return s, s[T] > 0
}

// File is the app's sample file in dir.
func File(dir, app string) string { return filepath.Join(dir, app+".db") }

// TopFile is the app's latest top statements in dir.
func TopFile(dir, app string) string { return filepath.Join(dir, app+".dbtop") }

// Append adds the sample to the app's file, rotating it first when it is full.
func Append(dir, app string, s Sample) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	f := File(dir, app)
	if fi, err := os.Stat(f); err == nil && fi.Size() >= rotateAt {
		if err := os.Rename(f, f+".1"); err != nil {
			return fmt.Errorf("rotate %s: %w", f, err)
		}
	}
	w, err := os.OpenFile(f, os.O_WRONLY|os.O_APPEND|os.O_CREATE, fileMode)
	if err != nil {
		return err
	}
	_, err = w.WriteString(s.Line() + "\n") // one write: a reader never sees half a line
	if cerr := w.Close(); err == nil {
		err = cerr
	}
	return err
}

// Query is one normalized statement of pg_stat_statements (constants are $1, $2: no values).
type Query struct {
	Calls, TotalMs, MeanUs, Rows int64
	Text                         string // at most MaxText characters, on one line
}

// MaxText is how much of a statement's text is kept.
const MaxText = 500

// OneLine makes a statement's text safe for a tab-separated line: every control character
// (newlines, tabs) becomes a space, runs of spaces one, and it is cut to MaxText characters.
func OneLine(s string) string {
	var b strings.Builder
	space, n := false, 0
	for _, r := range s {
		if r < 0x20 || r == 0x7f || r == ' ' || (r >= 0x80 && r < 0xa0) {
			space = true
			continue
		}
		if space && b.Len() > 0 {
			b.WriteByte(' ')
			n++
		}
		space = false
		if n >= MaxText {
			break
		}
		b.WriteRune(r)
		n++
	}
	return b.String()
}

// WriteTop replaces the app's top file with qs (taken at time t); none removes it.
func WriteTop(dir, app string, t int64, qs []Query) error {
	f := TopFile(dir, app)
	if len(qs) == 0 {
		if err := os.Remove(f); err != nil && !os.IsNotExist(err) {
			return err
		}
		return nil
	}
	var b strings.Builder
	fmt.Fprintf(&b, "t\t%d\n", t)
	for _, q := range qs {
		fmt.Fprintf(&b, "q\t%d\t%d\t%d\t%d\t%s\n", q.Calls, q.TotalMs, q.MeanUs, q.Rows, OneLine(q.Text))
	}
	return atomicfile.Write(f, []byte(b.String()), atomicfile.Mode(fileMode))
}

// ReadTop reads the app's top file: when it was taken and the statements (none: no file).
func ReadTop(dir, app string) (int64, []Query) {
	b, err := os.ReadFile(TopFile(dir, app))
	if err != nil {
		return 0, nil
	}
	var t int64
	var qs []Query
	for _, l := range strings.Split(string(b), "\n") {
		p := strings.SplitN(l, "\t", 6)
		switch {
		case len(p) == 2 && p[0] == "t":
			t, _ = strconv.ParseInt(p[1], 10, 64)
		case len(p) == 6 && p[0] == "q":
			q := Query{Text: OneLine(p[5])}
			var e [4]error
			q.Calls, e[0] = strconv.ParseInt(p[1], 10, 64)
			q.TotalMs, e[1] = strconv.ParseInt(p[2], 10, 64)
			q.MeanUs, e[2] = strconv.ParseInt(p[3], 10, 64)
			q.Rows, e[3] = strconv.ParseInt(p[4], 10, 64)
			if e[0] == nil && e[1] == nil && e[2] == nil && e[3] == nil {
				qs = append(qs, q)
			}
		}
	}
	return t, qs
}
