package gate

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"

	"tando/srv/internal/atomicfile"
	"tando/srv/internal/bashread"
	"tando/srv/internal/lock"
	"tando/srv/internal/run"
	"tando/srv/internal/valid"
)

// receiveConfined runs the rsync receiver as the deploy user in the transient unit
// tando-rx-<app>@<nonce> (one at a time per app, see rxPatterns), with stdin and stdout passed through.
// Root watches incoming/ meanwhile and stops the unit when it holds more than the app's limit of
// bytes or entries (checked every second or more, depending on how long a walk takes: the
// overshoot is what the receiver writes in one interval); one file is capped by the kernel
// (LimitFSIZE). The unit also ends with the lease (RuntimeMaxSec). held is the lease lock: it is
// given back once the unit runs, so an activation that freezes the lease afterwards stops it.
func (g *Gate) receiveConfined(app string, remain int64, opts []string, held *lock.Lock) error {
	lim := g.limits()
	nonce, err := g.writeTicket(app)
	if err != nil {
		return err
	}
	u, unit, inc := "tando-d-"+app, "tando-rx-"+app+"@"+nonce, g.incoming(app)
	// the unit tando-rx-<app>@<nonce> as the deploy user, writing nothing but incoming/, no network, no
	// privileges, a file size limit of the app's largest file and a run time of what is left of
	// the lease
	argv := []string{"systemd-run", "--quiet", "--pipe", "--wait", "--collect", "--unit=" + unit,
		"-p", "User=" + u, "-p", "Group=" + u, "-p", "UMask=0022", "-p", "Environment=LC_ALL=C",
		"-p", "ProtectSystem=strict", "-p", "ReadWritePaths=" + inc, "-p", "ProtectHome=yes",
		"-p", "PrivateTmp=yes", "-p", "PrivateDevices=yes", "-p", "PrivateNetwork=yes", "-p", "IPAddressDeny=any",
		"-p", "InaccessiblePaths=-/run/user", "-p", "NoNewPrivileges=yes", "-p", "RestrictSUIDSGID=yes",
		"-p", "CapabilityBoundingSet=", "-p", "ProtectKernelTunables=yes", "-p", "ProtectKernelModules=yes",
		"-p", "ProtectControlGroups=yes", "-p", "ProtectProc=invisible", "-p", "RestrictNamespaces=yes",
		"-p", "LockPersonality=yes", "-p", "MemoryMax=512M", "-p", "TasksMax=16",
		"-p", fmt.Sprintf("LimitFSIZE=%d", lim.MaxFile), "-p", fmt.Sprintf("RuntimeMaxSec=%d", remain),
		"--", g.P.Gate, "rx", app, nonce}
	argv = append(argv, opts...)
	done := make(chan error, 1)
	go func() {
		defer func() {
			if recover() != nil {
				done <- die("internal error")
			}
		}()
		time.Sleep(rxStartDelay)
		_, err := g.Env.Run.Output(context.Background(), run.Cmd{Argv: argv, Stdin: g.Stdin, Stdout: g.Stdout,
			Stderr: g.Stderr, Timeout: time.Duration(remain+60) * time.Second})
		done <- err
	}()
	result, finished := g.waitActive(app, unit+".service", done)
	held.Release()
	why, result, finished := watchUpload(inc, lim, done, result, finished)
	if why != "" {
		g.stopRx(app)
		fmt.Fprintf(g.Stderr, "tando-gate: upload stopped: incoming/ holds %s (the app's limit)\n", why)
		g.log("auth.notice", fmt.Sprintf("tando-d-%s upload stopped: %s", app, why))
		if !finished {
			result = <-done
		}
	}
	if why != "" {
		return Exit{1}
	}
	if result != nil {
		return Exit{ExitCode(result)}
	}
	return nil
}

// waitActive waits until the receiver's unit is running or systemd-run has returned, so the
// lease lock is given back only then; finished: done delivered the receiver's result. There is
// no other limit (systemd-run's own timeout is the lease's): given back earlier, an end or an
// activation could find no unit to stop while systemd was still creating it (the first Go version
// gave up after 5 s; a slow start then wrote after end). end and activate wait for the lock, at
// most 30 s, and refuse ("lease lock busy") rather than go on.
func (g *Gate) waitActive(app, unit string, done <-chan error) (result error, finished bool) {
	for {
		if units, _ := g.rxUnits(app); units[unit] == "active" {
			break
		}
		select {
		case result = <-done:
			finished = true
		case <-time.After(100 * time.Millisecond):
		}
		if finished {
			break
		}
	}
	return result, finished
}

// watchUpload is the upload's watchdog: until the receiver ends, it measures incoming/ and says
// why (why != "") the upload must stop. One walk for bytes and entries; the next check waits at
// least 4x as long as this one took (so the watchdog uses at most a fifth of a core even near
// the file limit), and at least 250 ms. Once more when the receiver has ended: an upload faster
// than one interval is still refused (the shell version checked once a second and missed those).
func watchUpload(inc string, lim Limits, done <-chan error, result error, finished bool) (string, error, bool) {
	why := ""
	next := 250 * time.Millisecond
	check := func() {
		t0 := time.Now()
		bytes, n, err := measure(inc, lim.MaxBytes, lim.MaxFiles+1)
		iv := time.Since(t0) * 4
		switch {
		case err != nil && !gone(err):
			// a tree the watchdog cannot walk is not a tree it lets grow (the shell's find
			// ignored errors)
			why = "entries it cannot measure"
		case bytes > lim.MaxBytes:
			why = fmt.Sprintf("more than %d MB", lim.MaxBytes>>20)
		case n > lim.MaxFiles+1:
			why = fmt.Sprintf("more than %d files", lim.MaxFiles)
		}
		next = max(iv, 250*time.Millisecond)
	}
	for !finished && why == "" {
		select {
		case result = <-done:
			finished = true
		case <-time.After(next):
			check()
		}
	}
	if why == "" {
		check()
	}
	return why, result, finished
}

// Receiver units are named tando-rx-<app>@<nonce>.service, a new name for every receiver (the
// nonce is its ticket's). A fixed name (the shell version's, and the first Go version's) could
// not be used again until systemd had collected the ended unit, and systemd collects only when it
// is otherwise idle: on a loaded host an upload right after the last one failed ("Unit
// tando-rx-<app>.service was already loaded"), after waiting up to 30 s for nothing.
//
// One receiver per app is the lease lock's guarantee: every receiver is started under it, after
// rxFree found none of the app's receivers running, and the lock is given back only once the new
// unit runs or systemd-run has returned (waitActive). stopRx ends them all by pattern.

// rxPatterns match the app's receiver units (the old fixed name too, for one started before an
// update). App names have no "@", so alpha's patterns never match alpha-2's units.
func rxPatterns(app string) []string {
	return []string{"tando-rx-" + app + ".service", "tando-rx-" + app + "@*.service"}
}

// rxUnits lists the app's receiver units systemd has loaded, name -> active state. list-units
// does not load a unit, asking for one by name does.
func (g *Gate) rxUnits(app string) (map[string]string, error) {
	argv := append([]string{"systemctl", "list-units", "--all", "--plain", "--no-legend", "--full", "--"}, rxPatterns(app)...)
	o, err := g.quiet(30*time.Second, argv...)
	m := map[string]string{}
	for _, l := range bashread.LinesAll(o) {
		f := strings.Fields(l)
		if len(f) < 3 {
			continue
		}
		if n := f[0]; n == "tando-rx-"+app+".service" ||
			strings.HasPrefix(n, "tando-rx-"+app+"@") && strings.HasSuffix(n, ".service") {
			m[n] = f[2]
		}
	}
	return m, err
}

// rxFree checks, with the lease lock held, that none of the app's receivers runs: one that is
// active (or starting) refuses the upload; one being stopped is waited for (it may still hold
// incoming/ open); failed ones are reset (they would stay loaded).
func (g *Gate) rxFree(app string) error {
	deadline := time.Now().Add(rxGoneWait)
	for {
		units, err := g.rxUnits(app)
		stopping := ""
		for n, active := range units {
			switch active {
			case "active", "activating", "reloading":
				return die("rsync: another upload of %s is running", app)
			case "deactivating":
				stopping = n
			case "failed":
				g.quiet(30*time.Second, "systemctl", "reset-failed", "--", n)
			}
		}
		if err == nil && stopping == "" {
			return nil
		}
		if time.Now().After(deadline) {
			return die("rsync: the last upload of %s is still being stopped; try again", app)
		}
		time.Sleep(250 * time.Millisecond)
	}
}

// The receiver's ticket, CI/<app>/receiver (root 644; the home is root's, 711): a random nonce
// root writes under the lease lock just before it starts the unit, and passes to it. Rx refuses
// to run unless the file still holds its nonce. end and activate remove the ticket under the
// lease lock (closeUpload) before they stop anything, and every stopRx removes it first. So,
// after end or activate has given the lock back, a receiver either was running already (its unit
// active: endSessions' stopRx ends it; the lock is not given back by receive before the unit is
// active or systemd-run has returned) or checks its ticket after the removal and does not
// start: nothing of that upload session writes incoming/ any more. ended/frozen (root 600) keep
// a new receiver of the same lease from being started at all.
func (g *Gate) ticket(app string) string { return filepath.Join(g.home(app), "receiver") }

func (g *Gate) writeTicket(app string) (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	n := hex.EncodeToString(b)
	if err := atomicfile.Write(g.ticket(app), []byte(n+"\n"), atomicfile.Mode(0o644)); err != nil {
		return "", err
	}
	return n, nil
}

// closeUpload marks the lease's upload closed (file "ended" or "frozen": token=<lease token>)
// and removes the receiver's ticket; called with the lease lock held.
func (g *Gate) closeUpload(app, file, token string) error {
	if err := atomicfile.Write(filepath.Join(g.home(app), file), []byte("token="+token+"\n"), atomicfile.Mode(0o600)); err != nil {
		return err
	}
	if err := os.Remove(g.ticket(app)); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

var nonceRe = regexp.MustCompile(`^[0-9a-f]{32}$`)

// rxGoneWait: how long rxFree waits for a receiver being stopped.
const rxGoneWait = 30 * time.Second

// Rx is the receiver, as tando-d-<app>, inside the unit tando-rx-<app>@<nonce> (rx mode). The unit
// mounts everything read-only except incoming/, with private /tmp and /dev, no /run/user and no
// network, so a symlink in the upload cannot carry a write anywhere else. Symlinks that leave
// incoming/ are also removed before and after each receive.
func (g *Gate) Rx(args []string) error {
	// a few threads are enough, and the unit allows 16 tasks for this program and rsync together
	runtime.GOMAXPROCS(1)
	if g.Caller.InvocationID == "" {
		return die("rx runs inside its unit only")
	}
	app, nonce := "", ""
	if len(args) > 1 {
		app, nonce, args = args[0], args[1], args[2:]
	}
	a, ok := g.CallerApp(g.Caller.UID)
	if !ok || a != app || !valid.App(app) || g.Caller.UID != g.Caller.EUID {
		return die("rx: wrong user")
	}
	// the upload that started this receiver must still be open (its ticket, above), checked
	// before anything is written, even the removal of a link
	if t, err := os.ReadFile(g.ticket(app)); !nonceRe.MatchString(nonce) || err != nil || string(t) != nonce+"\n" {
		return die("rx: this upload was ended or stopped")
	}
	// root checked these; checked again so the receiver never runs with anything else
	if err := checkRsyncOpts(args); err != nil {
		return err
	}
	inc := g.incoming(app)
	if err := os.Chdir(inc); err != nil {
		return die("rx: no upload directory")
	}
	chmodDir(inc, 0o700) // (a mode the last upload gave it must not stop the walk)
	g.dropEscapingLinks(inc)
	argv := append([]string{"/usr/bin/rsync", "--server"}, args...)
	argv = append(argv, ".", inc+"/")
	_, err := g.Env.Run.Output(context.Background(), run.Cmd{Argv: argv, Dir: inc, Stdin: g.Stdin, Stdout: g.Stdout,
		Stderr: g.Stderr, Timeout: 2 * time.Hour})
	chmodDir(inc, 0o700) // rsync -p gave it the mode of the client's directory
	stripSetid(inc)
	g.dropEscapingLinks(inc)
	if err != nil {
		return Exit{ExitCode(err)}
	}
	return nil
}

// maxRxTree: entries kept to resolve links in rx mode (about 100 MB; the unit has 512)
const maxRxTree = 1000000

// dropEscapingLinks removes the symlinks under dir whose target, resolved, is not inside dir.
func (g *Gate) dropEscapingLinks(dir string) {
	t, err := readOwnTree(dir, maxRxTree)
	if err != nil {
		return
	}
	for _, rel := range t.escapingLinks() {
		unlinkLink(dir, rel)
	}
}
