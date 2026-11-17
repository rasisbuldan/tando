package hostcare

import (
	"strconv"
	"strings"

	"tando/srv/internal/atomicfile"
	"tando/srv/internal/bashread"
	"tando/srv/internal/out"
)

// The summary file: /var/lib/tando/hostcare/summary (root 600, in a root 700 directory),
// rewritten whole by every run (a temporary file in the same directory, fsync, rename), so a
// reader sees the last run or the one before, never a mix. Tab-separated rows; every field is
// cleaned (no tab, newline or control character); "-" is empty. docs/HOSTCARE.md documents it;
// the alert checks of tando-watch read the "alert" rows.
//
//	# tando-host summary, format 1 (docs/HOSTCARE.md)
//	summary 1 <at> <apt_at> <todo> <fail> <warn> <hostname>
//	alert   <check> <ok|bad|off> <since> <low|normal|high> <remind hours, 0 = default> <detail>
//	finding <id> <section> <ok|warn|fail|unknown> <since> <auto 0|1> <rank> <title> <detail> <fix>
//
// <at> is when the run collected its facts (epoch seconds), <apt_at> when apt's facts were;
// <since> when the alert (finding) turned bad, 0 while ok. A reader must ignore row types and
// trailing fields it does not know (fields are only ever appended), and should treat a summary
// whose <at> is older than 3 hours as stale (tando-host.timer runs hourly).

// SummaryVersion is the format's number (the second field of the summary row).
const SummaryVersion = "1"

// Counts are the to-do numbers of a set of findings.
func Counts(fs []Finding) (todo, fail, warn int) {
	for _, f := range fs {
		switch f.State {
		case "fail":
			fail++
		case "warn":
			warn++
		}
	}
	return fail + warn, fail, warn
}

// FormatSummary renders the summary file.
func FormatSummary(f Facts, fs []Finding, as []Alert) []byte {
	var b strings.Builder
	w := out.New(&b)
	b.WriteString("# tando-host summary, format 1 (docs/HOSTCARE.md)\n")
	todo, fail, warn := Counts(fs)
	w.Row("summary", SummaryVersion, i64(f.At), i64(f.Apt.At), strconv.Itoa(todo), strconv.Itoa(fail), strconv.Itoa(warn), f.Hostname)
	for _, a := range as {
		w.Row("alert", a.Check, a.State, i64(a.Since), a.Priority, strconv.Itoa(a.Remind), a.Detail)
	}
	for _, x := range fs {
		w.Row("finding", x.ID, x.Section, x.State, i64(x.Since), b01(x.Auto), strconv.Itoa(x.Rank), x.Title, x.Detail, x.Fix)
	}
	w.Flush()
	return []byte(b.String())
}

func (h *Host) writeSummary(f Facts, fs []Finding, as []Alert) error {
	if err := h.mkdir(); err != nil {
		return err
	}
	return atomicfile.Write(h.SummaryPath(), FormatSummary(f, fs, as), atomicfile.Mode(0o600))
}

// Brief is the summary row of the file at path: what `tando-status status` appends as its
// "hostcare" row (todo, fail, warn, at). ok is false when there is no readable summary.
func Brief(path string) (todo, fail, warn, at string, ok bool) {
	b := readFile(path, 64<<10)
	for _, l := range bashread.Lines(b) {
		p := bashread.Fields(l, 8)
		if p[0] == "summary" && p[1] == SummaryVersion {
			return p[4], p[5], p[6], p[2], true
		}
	}
	return "", "", "", "", false
}

func i64(n int64) string { return strconv.FormatInt(n, 10) }
func b01(b bool) string {
	if b {
		return "1"
	}
	return "0"
}
