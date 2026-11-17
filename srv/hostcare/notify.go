package hostcare

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"tando/srv/internal/fsinfo"
	"tando/srv/internal/run"
)

// notice hands a one-time message to the alert pipeline: a file in tando-watch's inbox
// (/var/lib/tando/watch/inbox, root 700; written whole, then renamed), which the next run of
// the checks sends through every notifier and deletes. The inbox takes the kinds "rollback" and
// "monitor" today: host care's notices go as "monitor" (sent with high priority, as
// "MONITOR host: <text>") until tando-watch knows a "care" kind (docs/HOSTCARE.md, "For
// tando-watch"). wait: run the checks now and wait for them (before a reboot: the message must
// leave first).
func (h *Host) notice(ctx context.Context, text string, wait bool) {
	wdir := filepath.Join(h.Env.Lib, "watch")
	if !fsinfo.DirNoFollow(wdir) {
		return // alerts were never set up here
	}
	in := filepath.Join(wdir, "inbox")
	if err := os.MkdirAll(in, 0o700); err != nil {
		return
	}
	name := strconv.FormatInt(h.now(), 10) + ".host.care-" + strconv.FormatInt(h.Env.Now().UnixNano()%1e9, 10)
	line := "monitor\thost\t-\t" + clean(text, 300) + "\n"
	tmp := filepath.Join(in, "."+name+".tmp")
	if os.WriteFile(tmp, []byte(line), 0o600) != nil || os.Rename(tmp, filepath.Join(in, name)) != nil {
		os.Remove(tmp)
		return
	}
	if wait {
		h.Env.Run.Output(ctx, run.Cmd{Argv: []string{"systemctl", "start", "tando-watch.service"}, Timeout: 90 * time.Second})
	} else {
		h.Env.Run.Output(ctx, run.Cmd{Argv: []string{"systemctl", "start", "--no-block", "tando-watch.service"}, Timeout: 20 * time.Second})
	}
}

// audit writes one line to tando's audit trail (tando audit) through tando-logs, as the agent
// does: verb, app "-", result (0 ok, 1 failed), a note.
func (h *Host) audit(ctx context.Context, verb string, ok bool, note string) {
	res := "0"
	if !ok {
		res = "1"
	}
	switch verb { // (constant verbs: the lint sees every argv)
	case "host-care":
		h.Env.Run.Output(ctx, run.Cmd{Argv: []string{"/opt/tando/bin/tando-logs", "audit-write", "host-care", "-", res, "tando-host: " + clean(note, 290)}, Timeout: 20 * time.Second})
	case "host-update":
		h.Env.Run.Output(ctx, run.Cmd{Argv: []string{"/opt/tando/bin/tando-logs", "audit-write", "host-update", "-", res, "tando-host: " + clean(note, 290)}, Timeout: 20 * time.Second})
	case "host-reboot":
		h.Env.Run.Output(ctx, run.Cmd{Argv: []string{"/opt/tando/bin/tando-logs", "audit-write", "host-reboot", "-", res, "tando-host: " + clean(note, 290)}, Timeout: 20 * time.Second})
	case "host-upgraded":
		h.Env.Run.Output(ctx, run.Cmd{Argv: []string{"/opt/tando/bin/tando-logs", "audit-write", "host-upgraded", "-", res, "tando-host: " + clean(note, 290)}, Timeout: 20 * time.Second})
	}
}
