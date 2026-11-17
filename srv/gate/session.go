package gate

import (
	"bytes"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
)

// Root mode works only for a process that sshd started for this deploy user with a key's forced
// command: walking up from here past root (this program, sudo), the first other process must be
// the gate as login shell, "tando-gate -c '<gate> key <id>'" (executable: this program's path),
// running entirely as the caller's uid, whose parent is the user's sshd session process and
// grandparent sshd's privileged root process. The key id and the request come from that process
// (its command line, set by sshd from the root-owned key file, and its initial environment),
// never from the caller. A process of the deploy user that sshd did not start for a key (any
// foothold) is refused.
//
// The shell version expected bash running the script (`bash <gate> -c ...`); the Go gate is
// the login shell itself, so sshd's argv is ["tando-gate", "-c", cmd] and /proc/<pid>/exe is the
// gate. A session that was opened before `tando host setup` replaced the script is refused (its
// login process is bash, or the replaced file is "(deleted)"): the next deploy works.

// Session is what root mode learns from the key's ssh session.
type Session struct {
	KeyID   string
	Request string // SSH_ORIGINAL_COMMAND of the login process ("" when it had none)
}

func (g *Gate) procFile(pid int, name string) string {
	return filepath.Join(g.Env.Proc, strconv.Itoa(pid), name)
}

// statusField is a field of /proc/<pid>/status ("PPid", "Uid") as words.
func (g *Gate) statusField(pid int, key string) []string {
	data, err := os.ReadFile(g.procFile(pid, "status"))
	if err != nil {
		return nil
	}
	for l := range strings.SplitSeq(string(data), "\n") {
		if v, ok := strings.CutPrefix(l, key+":"); ok {
			return strings.Fields(v)
		}
	}
	return nil
}

func (g *Gate) ppid(pid int) int {
	f := g.statusField(pid, "PPid")
	if len(f) != 1 {
		return -1
	}
	n, ok := uintOf(f[0])
	if !ok {
		return -1
	}
	return n
}

// uids: real, effective, saved and filesystem uid; nil when unknown.
func (g *Gate) uids(pid int) []int {
	f := g.statusField(pid, "Uid")
	if len(f) != 4 {
		return nil
	}
	r := make([]int, 4)
	for i, s := range f {
		n, ok := uintOf(s)
		if !ok {
			return nil
		}
		r[i] = n
	}
	return r
}

func allAre(u []int, want ...int) bool { return len(u) == 4 && slices.Equal(u, want) }

// sshdExe: the process runs OpenSSH's server binary (root-owned).
func (g *Gate) sshdExe(pid int) bool {
	e, err := os.Readlink(g.procFile(pid, "exe"))
	if err != nil || !slices.Contains(g.P.SSHD, e) {
		return false
	}
	fi, err := os.Stat(e)
	if err != nil {
		return false
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	return ok && st.Uid == 0
}

// BindSession finds the key's login process above this one (session_bind).
func (g *Gate) BindSession(uid int) (Session, error) {
	refused := die(msgSession)
	p := os.Getpid()
	for {
		p = g.ppid(p)
		if p <= 1 {
			return Session{}, refused
		}
		u := g.uids(p)
		// this program as root and sudo (real uid the caller's, the rest root) are passed
		if !allAre(u, 0, 0, 0, 0) && !allAre(u, uid, 0, 0, 0) {
			break
		}
	}
	k := p
	if !allAre(g.uids(k), uid, uid, uid, uid) {
		return Session{}, refused
	}
	if e, err := os.Readlink(g.procFile(k, "exe")); err != nil || e != g.P.Gate {
		return Session{}, refused
	}
	cmdline, err := os.ReadFile(g.procFile(k, "cmdline"))
	if err != nil {
		return Session{}, refused
	}
	a := strings.Split(strings.TrimSuffix(string(cmdline), "\x00"), "\x00")
	if len(a) != 3 || (a[0] != "tando-gate" && a[0] != g.P.Gate) {
		return Session{}, refused
	}
	id, err := ForcedKeyID(a[1:], g.P.Gate)
	if err != nil {
		return Session{}, refused
	}
	p1 := g.ppid(k)
	p2 := g.ppid(p1)
	if p1 <= 1 || p2 <= 0 || !allAre(g.uids(p1), uid, uid, uid, uid) || !g.sshdExe(p1) ||
		!allAre(g.uids(p2), 0, 0, 0, 0) || !g.sshdExe(p2) {
		return Session{}, refused
	}
	s := Session{KeyID: id}
	environ, err := os.ReadFile(g.procFile(k, "environ"))
	if err != nil {
		return Session{}, refused
	}
	for e := range bytes.SplitSeq(environ, []byte{0}) {
		if v, ok := bytes.CutPrefix(e, []byte("SSH_ORIGINAL_COMMAND=")); ok {
			s.Request = string(v) // the last one, as the shell's loop kept
		}
	}
	return s, nil
}
