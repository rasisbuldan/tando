package watch

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"

	"tando/srv/internal/decimal"
	"tando/srv/internal/fsinfo"
)

// recordUptime appends one line per app and run to $V/probe/<app> ("time class [ms]": ok, down,
// unhealthy, slow, saturated, hold, stopped), kept 7 days (trimmed once an hour), for tando
// health. Files of removed apps go at the hourly trim.
func recordUptime(t *tick) {
	dir := filepath.Join(t.w.Dir, "probe")
	os.Mkdir(dir, 0o700)
	for _, a := range t.apps {
		appendLine(filepath.Join(dir, a.name), decimal.Itoa(t.now)+" "+a.class+"\n")
	}
	if t.now-t.vs.n("ptrim", 0) < 3600 {
		return
	}
	t.vs.set("ptrim", decimal.Itoa(t.now))
	var files []string
	for _, g := range []string{"probe/*", "incidents/*.tsv", "tail/*"} {
		m, _ := filepath.Glob(filepath.Join(t.w.Dir, g))
		files = append(files, m...)
	}
	for _, f := range files {
		if strings.HasPrefix(filepath.Base(f), ".") || !fsinfo.RegularFollow(f) {
			continue
		}
		a := strings.TrimSuffix(filepath.Base(f), ".tsv")
		if !fsinfo.DirFollow(t.w.appDir(a)) {
			os.Remove(f)
			continue
		}
		if filepath.Base(filepath.Dir(f)) == "probe" {
			if b, err := os.ReadFile(f); err == nil && bytes.Count(b, []byte("\n")) > 11000 {
				trimLines(f, 11000, 10080)
			}
		}
		os.Chmod(f, 0o600)
	}
}
