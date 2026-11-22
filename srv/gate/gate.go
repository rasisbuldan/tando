// Package gate is tando-gate: restricted deploys for CI (docs/CI.md). Installed as
// /opt/tando/bin/tando-gate (root, 755).
//
// One login user per app, tando-d-<app>. Its login shell is this program, its home is root's, and
// sshd takes its keys from a root:tando-keys 0640 file through AuthorizedKeysCommand (the deploy
// user cannot read its own key ids). Every key line is
//
//	restrict,command="/opt/tando/bin/tando-gate key <keyid>" ssh-ed25519 ...
//
// The app is derived from the caller's uid, never from the request. Entry points (Key, Root, Rx,
// Admin):
//
//	-c "<gate> key <id>"  (deploy user; sshd runs the login shell with the forced command) one
//	                      request per ssh session: upload, begin/end the lease, activate,
//	                      deploy-status, status, releases, history. Nothing else.
//	root <app> <verb>     (root via sudo; sudoers names the exact argv per app) begin, end,
//	                      activate, receive. Bound to the calling ssh session: the key id and the
//	                      request are read from that session's processes, not from the caller.
//	rx <app> <opts...>    (deploy user, inside the sandboxed unit tando-rx-<app>@<nonce>) the rsync receiver
//	admin <verb> <app>    (root via the admin's sudo) install, key-add, key-ls, key-revoke, receive,
//	                      remove.
//
// Nothing from SSH_ORIGINAL_COMMAND reaches a shell or a command line: it is checked character by
// character, split into words, and parsed into a typed Request (request.go) against a fixed
// grammar; this program builds every argv itself from constants, the caller's identity and the
// checked values.
//
// Files (concerns):
//
//	gate.go       the Gate, its paths, errors, clean(), the process environment (Startup)
//	request.go    SSH_ORIGINAL_COMMAND -> Request; rsync.go: the rsync server options
//	params.go     root mode's key=value parameters on stdin
//	identity.go   passwd/group lookups, CallerApp (uid -> app)
//	session.go    root mode's binding to the key's ssh session (/proc)
//	keys.go       public keys, the key list, authorized_keys
//	conf.go       the shell's kv reader (first match wins), upload limits, the lease
//	tree.go       the upload tree: scan rules and symlink resolution (pure); fs_linux.go: walking
//	              it with directory descriptors, never following a link
//	procs.go      processes and cgroups: end_sessions, evict
//	receive.go    the confined receiver (systemd-run unit) and its watchdog; rx mode
//	sshd.go       the sshd drop-in; sudoers.go: the per-app sudo rule
//	users.go      deploy users: ensure, remove, deny lists, uids
//	keymode.go, rootmode.go, admin.go   the verbs
//
// Layer: domain. It imports internal/* only, and of those only small packages (run, env, valid,
// lock, atomicfile, out, bashread, decimal, fsinfo: `go list -deps ./cmd/tando-gate`): no other
// domain package, not daemon, not kvfile (the shell gate's kv is first-match: conf.go).
package gate

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"syscall"
	"time"

	"tando/srv/internal/env"
	"tando/srv/internal/out"
	"tando/srv/internal/run"
)

// uploadTimeout is tando-agent's: an older lease is abandoned.
const uploadTimeout = 900

// keysUser: sshd reads the key files as this user (AuthorizedKeysCommandUser).
const keysUser = "tando-keys"

// Paths are the files the gate reads and writes. OS() has the real ones; tests point them into a
// temporary directory.
type Paths struct {
	Root     string   // /opt/tando
	Gate     string   // /opt/tando/bin/tando-gate: this program, as sshd and sudoers name it
	Agent    string   // /opt/tando/bin/tando-agent
	CI       string   // /opt/tando/ci: CI/<app> is the home of tando-d-<app>, root-owned
	Passwd   string   // /etc/passwd
	Group    string   // /etc/group
	SSHDDrop string   // /etc/ssh/sshd_config.d/50-tando-ci.conf
	Sudoers  string   // /etc/sudoers.d
	CronDeny string   // /etc/cron.deny
	AtDeny   string   // /etc/at.deny
	HostKeys []string // the server's host public keys (known_hosts material for the CI)
	SSHD     []string // OpenSSH's server binaries (session binding)
	Tmp      []string // world-writable directories cleaned of an evicted user's files
	RunUser  string   // /run/user
	Musl     string   // glob of musl's loader (info: libc=musl)
	AuthTmp  string   // /tmp: where sshd writes a session's SSH_USER_AUTH file (ExposeAuthInfo)
}

// OSPaths are the real paths under root (/opt/tando).
func OSPaths(root string) Paths {
	return Paths{
		Root:     root,
		Gate:     filepath.Join(root, "bin", "tando-gate"),
		Agent:    filepath.Join(root, "bin", "tando-agent"),
		CI:       filepath.Join(root, "ci"),
		Passwd:   "/etc/passwd",
		Group:    "/etc/group",
		SSHDDrop: "/etc/ssh/sshd_config.d/50-tando-ci.conf",
		Sudoers:  "/etc/sudoers.d",
		CronDeny: "/etc/cron.deny",
		AtDeny:   "/etc/at.deny",
		HostKeys: []string{"/etc/ssh/ssh_host_ed25519_key.pub", "/etc/ssh/ssh_host_ecdsa_key.pub"},
		SSHD:     []string{"/usr/lib/openssh/sshd-session", "/usr/lib/openssh/sshd-auth", "/usr/sbin/sshd"},
		Tmp:      []string{"/tmp", "/var/tmp", "/dev/shm"},
		RunUser:  "/run/user",
		Musl:     "/lib/ld-musl-*",
		AuthTmp:  "/tmp",
	}
}

// Gate is one run of the program.
type Gate struct {
	Env    env.Env
	P      Paths
	Caller Caller
	Stdin  *os.File // passed to children as they are (the rsync stream must not be copied)
	Stdout *os.File
	Stderr *os.File

	// Owner, Group: who owns the directories and files root mode makes (root: 0, 0; a test runs
	// as itself). Kill ends a process (nil: SIGKILL; a test with a fake /proc replaces it).
	Owner, Group int
	Kill         func(pid int)

	krlForce bool // admin ctl-krl force: the list may have fewer entries than the current one (or none)

	// set once the caller is known: refusals of a deploy key go to the journal
	app, keyID string
}

func (g *Gate) kill(pid int) {
	if g.Kill != nil {
		g.Kill(pid)
		return
	}
	syscall.Kill(pid, syscall.SIGKILL)
}

// New is the gate on the real machine.
func New(e env.Env, c Caller) *Gate {
	return &Gate{Env: e, P: OSPaths(e.Root), Caller: c, Stdin: os.Stdin, Stdout: os.Stdout, Stderr: os.Stderr}
}

// Exit ends the program with Code and nothing printed: a program the gate ran has said why
// (rsync, tando-agent), or there is nothing to say.
type Exit struct{ Code int }

func (e Exit) Error() string { return fmt.Sprintf("exit status %d", e.Code) }

// ExitCode is the status a run error carries (an exit status, or 1).
func ExitCode(err error) int {
	if err == nil {
		return 0
	}
	var ec interface{ ExitCode() int }
	if errors.As(err, &ec) && ec.ExitCode() > 0 {
		return ec.ExitCode()
	}
	return 1
}

// die is the shell's die: an error whose text is the whole message.
func die(format string, a ...any) error { return fmt.Errorf(format, a...) }

// Messages the client and the tests match, word for word.
const (
	msgNoShell = "a deploy key runs tando deploy commands only (no shell)"
	msgSession = "root mode: not called from a deploy key's ssh session"
)

// logRefusal: refusals of a deploy key go to the journal too (auth facility), for an audit trail.
// Called with the error a verb ends with (deferred); does nothing before the key is known.
func (g *Gate) logRefusal(err error) {
	var ex Exit
	if err == nil || g.keyID == "" || errors.As(err, &ex) {
		return
	}
	a := g.app
	if a == "" {
		a = "?"
	}
	g.log("auth.notice", fmt.Sprintf("tando-d-%s key %s refused: %s", a, g.keyID, err))
}

// log writes one line to the journal through logger(1); failures are ignored, as in the shell.
func (g *Gate) log(prio, msg string) {
	g.Env.Run.Output(context.Background(), run.Cmd{
		Argv: []string{"logger", "-p", prio, "-t", "tando-gate", "--", msg}, Timeout: 10 * time.Second})
}

// quiet runs a program and drops its stderr (the shell's 2> /dev/null).
func (g *Gate) quiet(timeout time.Duration, argv ...string) ([]byte, error) {
	return g.Env.Run.Output(context.Background(), run.Cmd{Argv: argv, Timeout: timeout, Stderr: discard{}})
}

type discard struct{}

func (discard) Write(p []byte) (int, error) { return len(p), nil }

// clean is the gate's clean() for names in messages: C0 controls and DEL, and UTF-8 C1 (0xc2
// 0x80-0x9f), become "?"; at most 160 bytes. (Not out.Clean: this is what the shell printed,
// byte for byte: a lone 0x80-0x9f byte and bidi overrides are kept, and the cut is in bytes.)
func clean(s string) string {
	return out.Cleaner{Ctrl: '?', KeepBidi: true, MaxBytes: 160}.Clean(s)
}

var (
	keyIDRe = regexp.MustCompile(`^[0-9a-f]{12}$`)
	tokenRe = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	secsRe  = regexp.MustCompile(`^[0-9]{1,6}(\.[0-9])?$`)
)

func validKeyID(s string) bool { return keyIDRe.MatchString(s) }
func validToken(s string) bool { return tokenRe.MatchString(s) }
func validSecs(s string) bool  { return secsRe.MatchString(s) }

func (g *Gate) now() int64 { return g.Env.Now().Unix() }

// appDir is Root/apps/<app> (app checked by valid.App before).
func (g *Gate) appDir(app string) string { return filepath.Join(g.P.Root, "apps", app) }

// incoming is the app's upload directory.
func (g *Gate) incoming(app string) string { return filepath.Join(g.appDir(app), "incoming") }

// home is the deploy user's home, CI/<app>.
func (g *Gate) home(app string) string { return filepath.Join(g.P.CI, app) }
