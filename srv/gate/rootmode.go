package gate

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"tando/srv/internal/atomicfile"
	"tando/srv/internal/bashread"
	"tando/srv/internal/lock"
	"tando/srv/internal/out"
	"tando/srv/internal/run"
	"tando/srv/internal/valid"
)

// leaseLock is tando-agent's lease lock (<app>/lease.lock), the same file and flock.
func (g *Gate) leaseLock(app string) (*lock.Lock, error) {
	l, err := lock.Acquire(filepath.Join(g.appDir(app), "lease.lock"), 30*time.Second)
	if err != nil {
		return nil, die("lease lock busy")
	}
	return l, nil
}

// agent runs tando-agent as root with the caller passed on; its stderr is ours.
func (g *Gate) agent(stdout bool, secs int, args ...string) ([]byte, error) {
	c := run.Cmd{Argv: append([]string{g.P.Agent}, args...), Env: g.agentEnv(), Stderr: g.Stderr,
		Timeout: time.Duration(secs) * time.Second}
	if !stdout {
		c.Stdout = discard{}
	}
	return g.Env.Run.Output(context.Background(), c)
}

// keyActive: the key is still in the app's key list.
func (g *Gate) keyActive(app, id string) bool {
	data, err := os.ReadFile(filepath.Join(g.home(app), "keys"))
	return err == nil && keyActive(data, id)
}

var (
	tokenLineRe = regexp.MustCompile(`(?m)^token=([0-9a-f-]*)$`)
	idLineRe    = regexp.MustCompile(`^id=[0-9-]*$`)
)

// Root is root mode: tando-gate root <app> <verb>, through the deploy user's sudo rule.
func (g *Gate) Root(args []string) (err error) {
	defer func() { g.logRefusal(err) }()
	if g.Caller.EUID != 0 {
		return die("root mode runs through sudo")
	}
	if len(args) != 2 {
		return die("bad call")
	}
	app, verb := args[0], args[1]
	if !valid.App(app) {
		return die("bad app")
	}
	uid, ok := uintOf(g.Caller.SudoUID)
	if !ok || uid == 0 {
		return die("root mode is for deploy users")
	}
	if a, ok := g.CallerApp(uid); !ok || a != app {
		return die("the caller is not the deploy user of %s", app)
	}
	g.app = app
	s, err := g.BindSession(uid)
	if err != nil {
		return err
	}
	g.keyID = s.KeyID
	if !g.keyActive(app, s.KeyID) {
		return die("this key is not registered (revoked?)")
	}
	who := "ci-" + s.KeyID
	switch verb {
	case "receive":
		return g.rootReceive(app, who, s)
	case "begin":
		return g.rootBegin(app, uid, who, s.KeyID)
	case "end":
		return g.rootEnd(app, uid, who)
	case "activate":
		return g.rootActivate(app, uid, who)
	}
	return die("bad verb")
}

func (g *Gate) rootReceive(app, who string, s Session) error {
	req, err := ParseRequest(s.Request, Want{App: app, Agent: g.P.Agent, Incoming: g.incoming(app)})
	if err != nil {
		return err
	}
	if req.Verb != VRsync {
		return die("receive: the session did not ask for rsync")
	}
	held, err := g.leaseLock(app)
	if err != nil {
		return err
	}
	defer held.Release()
	l := g.lease(app)
	if l.Token == "" || l.Who != who || l.ID != "" {
		return die("rsync: no upload lease held by this key (tando deploy takes one)")
	}
	if g.frozen(app) == l.Token {
		return die("rsync: this upload is being activated; it can no longer change")
	}
	if kv(filepath.Join(g.home(app), "ended"), "token") == l.Token {
		return die("rsync: this upload was ended; it can no longer change")
	}
	if l.Remain <= 0 {
		return die("rsync: the upload lease expired")
	}
	if err := g.rxFree(app); err != nil {
		return err
	}
	return g.receiveConfined(app, l.Remain, req.Rsync, held)
}

func (g *Gate) rootBegin(app string, uid int, who, keyID string) error {
	o, err := g.agent(true, 5*60, "begin", app, who)
	if err != nil {
		return Exit{1}
	}
	m := tokenLineRe.FindSubmatch(o)
	// the lease is new: sessions left from an earlier upload must not write into this one
	if err := g.endSessions(app, uid); err != nil {
		if m != nil {
			g.agent(false, 5*60, "end", app, string(m[1]))
		}
		return err
	}
	w := out.New(g.Stdout)
	if m != nil {
		w.KV("token", string(m[1]))
	}
	if err := w.Flush(); err != nil {
		return err
	}
	st := filepath.Join(g.home(app), "state")
	if err := mkdirExact(st, 0o700, g.Owner, g.Group); err != nil {
		return err
	}
	return atomicfile.Write(filepath.Join(st, "used-"+keyID), fmt.Appendf(nil, "used=%d\n", g.now()), atomicfile.Mode(0o600))
}

func (g *Gate) rootEnd(app string, uid int, who string) error {
	p, err := ReadParams(g.Stdin)
	if err != nil {
		return err
	}
	if !validToken(p.Token) {
		return die("bad token")
	}
	// the lease must be this key's, with this token, before anything is stopped
	held, err := g.leaseLock(app)
	if err != nil {
		return err
	}
	l := g.lease(app)
	if l.Token != p.Token || l.Who != who || l.ID != "" {
		held.Release()
		return die("end: no upload lease of this key with that token")
	}
	// closed under the lock, before anything is stopped: no receiver of this lease starts from
	// now (receive refuses an ended lease; a receiver whose unit is still being created finds its
	// ticket gone), and one that runs is ended below (receive.go has the argument)
	err = g.closeUpload(app, "ended", p.Token)
	held.Release()
	if err != nil {
		return err
	}
	if err := g.endSessions(app, uid); err != nil {
		return err
	}
	if _, err := g.agent(false, 5*60, "end", app, p.Token); err != nil {
		return Exit{1}
	}
	w := out.New(g.Stdout)
	w.KV("ok", "1")
	return w.Flush()
}

func (g *Gate) rootActivate(app string, uid int, who string) error {
	p, err := ReadParams(g.Stdin)
	if err != nil {
		return err
	}
	if !validToken(p.Token) || !validSecs(p.Build) || !validSecs(p.Upload) {
		return die("bad parameters")
	}
	// 1. freeze: this key's lease, not yet activated; a receiver started from now is refused
	held, err := g.leaseLock(app)
	if err != nil {
		return err
	}
	l := g.lease(app)
	if l.Token != p.Token || l.Who != who || l.ID != "" {
		held.Release()
		return die("this upload no longer holds %s's upload lease (another deploy took it over after this one stopped writing, or it is older than %d min); nothing was activated: run the deploy again", app, uploadTimeout/60)
	}
	if g.frozen(app) == p.Token {
		held.Release()
		return die("this upload is already being activated")
	}
	err = g.closeUpload(app, "frozen", p.Token)
	held.Release()
	if err != nil {
		return err
	}
	// 2. stop the receiver and every other session of this user: nothing writes incoming/ now
	if err := g.endSessions(app, uid); err != nil {
		g.agent(false, 5*60, "end", app, p.Token)
		return err
	}
	// 3. check the frozen upload; tando-agent then copies it and checks the root-owned copy
	inc := g.incoming(app)
	chmodDir(inc, 0o700)
	if msg := g.scanUpload(app, inc, uint32(uid)); msg != "" {
		g.agent(false, 5*60, "end", app, p.Token)
		return die("%s", msg)
	}
	o, err := g.agent(true, 2*60*60, "activate", app, p.Token, p.Build, p.Upload)
	if err != nil {
		return Exit{1}
	}
	w := out.New(g.Stdout)
	for _, line := range bashread.LinesAll(o) {
		switch {
		case idLineRe.MatchString(line):
			w.KV("id", strings.TrimPrefix(line, "id="))
		case line == "same=1":
			w.KV("same", "1")
		}
	}
	return w.Flush()
}

// scanUpload checks the frozen upload before root copies it (tree.go); "" when it may be.
// Root only reads names and metadata here, never contents.
func (g *Gate) scanUpload(app, dir string, uid uint32) string {
	lim := g.limits()
	container := kv(filepath.Join(g.appDir(app), "app.conf"), "recipe") == "container"
	var s scanResult
	t, over, err := readTree(dir, lim.MaxFiles, func(n *node) { s.see(n, uid) })
	if err != nil {
		return "could not read the upload"
	}
	s.over = over
	return s.verdict(t, container, lim)
}

// mkdirExact makes dir (or keeps it) a real directory with exactly this mode and owner (install
// -d -m -o -g), refusing a symlink in its place.
func mkdirExact(dir string, mode os.FileMode, uid, gid int) error {
	if err := os.Mkdir(dir, mode); err != nil && !os.IsExist(err) {
		return err
	}
	fi, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	if !fi.IsDir() {
		return fmt.Errorf("%s is not a directory", dir)
	}
	if err := os.Lchown(dir, uid, gid); err != nil {
		return err
	}
	if err := chmodDir(dir, uint32(mode)); err != nil {
		return err
	}
	return nil
}
