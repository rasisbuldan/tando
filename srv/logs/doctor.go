package logs

import (
	"context"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"tando/srv/internal/apps"
	"tando/srv/internal/fsinfo"
	"tando/srv/internal/out"
	"tando/srv/internal/run"
)

var reDiskUse = regexp.MustCompile(`[0-9.]*[KMGT]`)

// LogDoctor (log-doctor): the check rows of `tando doctor` for logging.
func (l *Logs) LogDoctor(ctx context.Context, w *out.Writer) {
	h := l.loadHost()
	if fsinfo.RegularFollow(filepath.Join(l.P.Systemd, "journald.conf.d", "tando.conf")) {
		used := "?"
		if b, err := l.Env.Run.Output(ctx, run.Cmd{Argv: []string{"journalctl", "--disk-usage"}}); err == nil {
			if m := reDiskUse.Find(b); m != nil {
				used = string(m)
			}
		}
		w.Row("check", "ok", "main journal", "capped at "+hostSetting(h, "journal_max")+" ("+used+" used)")
	} else {
		w.Row("check", "warn", "main journal", "no tando cap: run tando host setup")
	}
	names, _ := apps.Names(l.Env.Root)
	var miss []string
	var sum int64
	for _, n := range names {
		a, err := l.app(n)
		if err != nil || !fsinfo.RegularFollow(a.nsConf()) {
			miss = append(miss, n)
			continue
		}
		sum += sizeBytes(a.setting("log_max")) + a.roll().Max
	}
	for _, n := range names {
		// (marked by the monitor when it left files out: see logNames)
		if a, err := l.app(n); err == nil {
			if b, err := readCapped(filepath.Join(a.scanDir(), "toomany"), 64); err == nil && len(b) > 0 {
				w.Row("check", "warn", "request log", n+": too many files in "+a.logDir()+" ("+
					strings.TrimSpace(string(b))+" over "+strconv.Itoa(maxLogFiles)+" left out): remove what is not Caddy's")
			}
		}
	}
	if len(miss) > 0 {
		w.Row("check", "warn", "app logs", "no log cap yet for: "+strings.Join(miss, " ")+" (tando up applies it)")
	} else {
		w.Row("check", "ok", "app logs", strconv.Itoa(len(names))+" apps in their own capped journals")
	}
	// the caps can only fill what is still free: compare what the logs may still grow by (the
	// caps minus what they hold now) with the free space
	var held int64
	var dirs []string
	if ents, err := os.ReadDir(l.P.Journal); err == nil {
		for _, e := range ents {
			if m, _ := filepath.Match("*.tando-*", e.Name()); m {
				dirs = append(dirs, filepath.Join(l.P.Journal, e.Name()))
			}
		}
	}
	if ents, err := os.ReadDir(l.P.LogDir); err == nil {
		for _, e := range ents {
			dirs = append(dirs, filepath.Join(l.P.LogDir, e.Name()))
		}
	}
	for _, d := range dirs {
		if fsinfo.DirFollow(d) {
			n, _ := diskUsage(d)
			held += n
		}
	}
	tot, avail, _ := diskKB(l.P.VarLog)
	mb := func(n int64) string { return strconv.FormatInt(n/1048576, 10) }
	// the budget the defaults are split from (log_budget): explicit caps can add up past it
	if bud := l.logBudgetMB(tot); bud > 0 {
		if sum/1048576 > bud {
			w.Row("check", "warn", "log budget", "app log caps "+mb(sum)+" MB, over log_budget "+strconv.FormatInt(bud, 10)+
				" MB: lower log_max of the largest apps in tando.conf, or raise log_budget (tando host setup <host> log_budget=<size>)")
		} else {
			w.Row("check", "ok", "log budget", mb(sum)+" MB of "+strconv.FormatInt(bud, 10)+" MB (log_budget) for "+strconv.Itoa(len(names))+" apps")
		}
	}
	if sum-held > avail*1024 {
		w.Row("check", "warn", "log caps", "app log caps "+mb(sum)+" MB: they may still grow by "+mb(sum-held)+
			" MB, only "+strconv.FormatInt(avail/1024, 10)+" MB free (lower log_max in tando.conf)")
	} else {
		w.Row("check", "ok", "log caps", mb(sum)+" MB of app log caps ("+mb(held)+" MB used), "+
			strconv.FormatInt(avail/1024, 10)+" MB free")
	}
}
