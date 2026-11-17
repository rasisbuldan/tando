package gate

import (
	"regexp"
	"strings"

	"tando/srv/internal/decimal"
)

// Caller is what the gate takes from the environment it was started with, and from nothing
// else. The binary runs as the deploy user's login shell (sshd: the client sends only LANG and
// LC_* there, and the drop-in replaces those), through sudo (env_reset, and the sudoers rule
// repeats it), inside a systemd unit (Environment= only), and through the admin's sudo.
//
// Decided per variable (docs/CI.md, "the gate's process environment"):
//
//   - SSH_ORIGINAL_COMMAND: the request (key mode). Root mode never reads its own: it reads the
//     one of the key's login process from /proc (session.go).
//   - SUDO_UID, SUDO_USER: who called through sudo; root mode checks SUDO_UID against the deploy
//     user, admin mode refuses a deploy user, key-add records SUDO_USER, and both are passed on to
//     tando-agent (its audit line names the admin).
//   - INVOCATION_ID: rx mode runs only inside its systemd unit.
//   - everything else is dropped: PATH, HOME, TMPDIR, IFS-like and locale variables play no part
//     (children get run.BaseEnv: a fixed PATH and LC_ALL=C), LD_* do nothing to a static binary
//     and never reach a child, SSH_* other than the request are not read.
//   - GODEBUG, GOTRACEBACK, GOGC, GOMEMLIMIT, GOMAXPROCS are read by the Go runtime before main
//     runs, so dropping them is too late: as root the gate refuses to run when one is set
//     (UnsafeRuntimeEnv). sudo's env_reset removes them, so this never fires in a real call.
//
// The working directory and umask are set by main (/ and 022); nothing depends on the caller's.
type Caller struct {
	SSHCommand   string
	SudoUID      string
	SudoUser     string
	InvocationID string
	UID, EUID    int
}

// runtimeVars are read by the Go runtime itself, before main.
var runtimeVars = []string{"GODEBUG", "GOTRACEBACK", "GOGC", "GOMEMLIMIT", "GOMAXPROCS"}

// sudoUserRe: what SUDO_USER may be to be recorded or passed on (a user name).
var sudoUserRe = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}$`)

// TakeEnv reads the variables the gate uses from environ (os.Environ()) and nothing else; the
// caller then clears the process environment.
func TakeEnv(environ []string, uid, euid int) Caller {
	c := Caller{UID: uid, EUID: euid}
	for _, kv := range environ {
		k, v, ok := strings.Cut(kv, "=")
		if !ok {
			continue
		}
		switch k {
		case "SSH_ORIGINAL_COMMAND":
			c.SSHCommand = v
		case "SUDO_UID":
			c.SudoUID = v
		case "SUDO_USER":
			if sudoUserRe.MatchString(v) {
				c.SudoUser = v
			}
		case "INVOCATION_ID":
			c.InvocationID = v
		}
	}
	return c
}

// UnsafeRuntimeEnv names the Go runtime variables set in environ (see Caller).
func UnsafeRuntimeEnv(environ []string) []string {
	var bad []string
	for _, kv := range environ {
		k, _, _ := strings.Cut(kv, "=")
		for _, r := range runtimeVars {
			if k == r {
				bad = append(bad, k)
			}
		}
	}
	return bad
}

// agentEnv is the environment of tando-agent run as root: the fixed one, plus who called (its
// audit line), as the shell gate passed them on.
func (g *Gate) agentEnv() []string {
	e := []string{"PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL=C"}
	if g.Caller.SudoUser != "" {
		e = append(e, "SUDO_USER="+g.Caller.SudoUser)
	}
	if _, ok := uintOf(g.Caller.SudoUID); ok {
		e = append(e, "SUDO_UID="+g.Caller.SudoUID)
	}
	return e
}

// uintOf parses a uid, gid or pid: digits only, at most 10, at most 2^31-1.
func uintOf(s string) (int, bool) {
	n, ok := decimal.Parse(s, 10)
	if !ok {
		return 0, false
	}
	return int(n), n <= 1<<31-1
}
