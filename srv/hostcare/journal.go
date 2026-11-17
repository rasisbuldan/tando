package hostcare

import (
	"context"
	"regexp"
	"time"

	"tando/srv/internal/run"
)

var cursorRe = regexp.MustCompile(`^[A-Za-z0-9=;_-]{1,512}$`)

// journal reads what the kernel and sshd logged since the last run (from the saved cursor; the
// first run reads 24 hours), at most 5000 entries, and counts I/O errors, OOM kills and failed
// ssh logins per hour in the state. One journalctl for both: the kernel's transport, and sshd's
// messages as root (_UID=0: a user's `logger -t sshd` is not sshd).
func (h *Host) journal(ctx context.Context, st *State, f *Facts) {
	argv := []string{"journalctl", "--no-pager", "-q", "-o", "json", "--output-fields=MESSAGE,_TRANSPORT,SYSLOG_IDENTIFIER", "-n", "5000"}
	if c := st.get("jcursor"); cursorRe.MatchString(c) {
		argv = append(argv, "--after-cursor="+c)
	} else {
		argv = append(argv, "--since=-24h")
	}
	argv = append(argv, "_TRANSPORT=kernel", "+", "SYSLOG_IDENTIFIER=sshd", "_UID=0", "+", "SYSLOG_IDENTIFIER=sshd-session", "_UID=0")
	b, err := h.Env.Run.Output(ctx, run.Cmd{Argv: argv, Timeout: 20 * time.Second})
	if err != nil {
		st.del("jcursor") // (a cursor the journal no longer has: the next run reads 24 h again)
	} else {
		for _, e := range ParseJournal(b, 5000) {
			switch {
			case e.Transport == "kernel":
				switch KernelEvent(e.Message) {
				case "ioerr":
					st.addEvent("ioerr", e.At)
					st.set("ev.ioerr.last", clean(e.Message, 200))
				case "oom":
					st.addEvent("oom", e.At)
				}
			case e.Ident == "sshd" || e.Ident == "sshd-session":
				if SSHFailure(e.Message) {
					st.addEvent("sshfail", e.At)
				}
			}
		}
		if c := lastCursor(b); cursorRe.MatchString(c) {
			st.set("jcursor", c)
		}
	}
	now := f.At
	f.Events = Events{IOErr: st.events("ioerr", now), OOM: st.events("oom", now), SSHFail: st.events("sshfail", now)}
	if f.Events.IOErr > 0 {
		f.Events.IOErrLast = st.get("ev.ioerr.last")
	} else {
		st.del("ev.ioerr.last")
	}
}

// lastCursor is the __CURSOR of the last entry.
func lastCursor(b []byte) string {
	ls := lines(b, 5000)
	for i := len(ls) - 1; i >= 0; i-- {
		const k = `"__CURSOR":"`
		l := ls[i]
		for j := 0; j+len(k) < len(l); j++ {
			if l[j:j+len(k)] == k {
				rest := l[j+len(k):]
				for e := 0; e < len(rest); e++ {
					if rest[e] == '"' {
						return rest[:e]
					}
				}
			}
		}
	}
	return ""
}
