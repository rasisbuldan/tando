package status

import (
	"context"
	"io"
	"strings"

	"tando/srv/internal/out"
)

// AgentEnv is the environment `tando-agent recover` gets (Collector.AgentEnv), taken from the
// caller's through lookup (main passes os.LookupEnv): sudo's secure PATH and what the agent
// itself reads (the locale, SUDO_USER for the owner of a recreated incoming/), values without
// control characters or blanks only.
func AgentEnv(lookup func(string) (string, bool)) []string {
	e := []string{"PATH=" + SecurePath}
	for _, k := range []string{"LANG", "LC_ALL", "LC_CTYPE", "SUDO_USER", "SUDO_UID", "SUDO_GID"} {
		if v, ok := lookup(k); ok && out.Clean(v) == v && !strings.ContainsAny(v, " \t") {
			e = append(e, k+"="+v)
		}
	}
	return e
}

// Remote answers `status [app]` from elsewhere: tandod, which keeps the systemd connection and
// has the log, alert and metrics rows in-process, so nothing is started (main passes
// proto.AskStatus). ok false: no answer to use.
type Remote func(ctx context.Context, app string) (body []byte, ok bool)

// StatusVia is the verb status as tando-status runs it. As root it asks remote first and writes
// its answer whole (rows tandod's out.Writer made); with no answer it collects itself (also for
// the error messages, which stay this program's). The skeleton repair of a half-deleted app
// directory is done here before asking: the daemon's sandbox cannot write /opt/tando.
// Trace, when set, is told how the answer came ("via tandod" or "direct").
func (c *Collector) StatusVia(ctx context.Context, w io.Writer, name string, remote Remote) error {
	if c.Env.EUID == 0 && remote != nil {
		if name != "" {
			c.Skeleton(name)
		}
		if body, ok := remote(ctx, name); ok {
			if _, err := w.Write(body); err == nil {
				c.trace("via tandod")
				return nil
			}
		}
	}
	c.trace("direct")
	return c.Status(ctx, w, name)
}

func (c *Collector) trace(how string) {
	if c.Trace != nil {
		io.WriteString(c.Trace, "tando-status: "+how+"\n")
	}
}
