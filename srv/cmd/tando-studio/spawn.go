package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"tando/srv/internal/out"
	"tando/srv/studio"
)

// Spawner starts helpers for real: `<bin> serve --fd ...` as the app's user (its primary group,
// no supplementary groups), its listening socket passed as fd 3 from a directory only root
// enters (Run/h), stdin a pipe the front holds (its EOF, the front gone, ends the helper),
// stdout the ready line and the backend pids, which go to Lower.
type Spawner struct {
	Svc   *studio.Service
	Run   string
	Bin   string
	Lower func(app string, pid int)
}

// appUser: the app's user (app.conf user=, else tando-<app>) -> uid, gid
func (sp *Spawner) appUser(app string) (uint32, uint32, error) {
	name, ok := sp.Svc.AppConf(app, "user")
	if !ok {
		return 0, 0, errors.New("no such app: " + app)
	}
	if name == "" {
		name = "tando-" + app
	}
	u, err := user.Lookup(name)
	if err != nil {
		return 0, 0, errors.New("the user " + name + " of " + app + " does not exist")
	}
	uid, err1 := strconv.ParseUint(u.Uid, 10, 32)
	gid, err2 := strconv.ParseUint(u.Gid, 10, 32)
	if err1 != nil || err2 != nil || uid == 0 || gid == 0 {
		return 0, 0, errors.New("the user of " + app + " is root or unreadable: the studio does not run as root")
	}
	return uint32(uid), uint32(gid), nil
}

// capBuf keeps the last 4 KB written (a helper's stderr: why it did not start)
type capBuf struct {
	mu sync.Mutex
	b  []byte
}

func (c *capBuf) Write(p []byte) (int, error) {
	c.mu.Lock()
	c.b = append(c.b, p...)
	if len(c.b) > 4096 {
		c.b = c.b[len(c.b)-4096:]
	}
	c.mu.Unlock()
	return len(p), nil
}

func (c *capBuf) last() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	ls := strings.Split(strings.TrimSpace(string(c.b)), "\n")
	return strings.TrimPrefix(out.Clean(ls[len(ls)-1]), "tando-studio: ")
}

// Spawn: SvcConfig.Spawn. The one program the front starts: its own binary (Bin, from
// os.Executable), as `serve --fd` (the AST test in srv/studio holds it to that).
func (sp *Spawner) Spawn(h *studio.Helper) error {
	uid, gid, err := sp.appUser(h.App)
	if err != nil {
		return err
	}
	dir := filepath.Join(sp.Run, "h")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	path := filepath.Join(dir, studio.Rnd(9)+".s")
	ln, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		return err
	}
	ln.SetUnlinkOnClose(false)
	f, err := ln.File()
	ln.Close()
	if err != nil {
		os.Remove(path)
		return err
	}
	cmd := exec.Command(sp.Bin, "serve", "--app", h.App, "--host", h.Host, "--admin", h.Admin,
		"--port", strconv.Itoa(h.Port), "--idle-s", strconv.Itoa(int(studio.HelperIdle/time.Second)), "--fd")
	cmd.ExtraFiles = []*os.File{f}
	cmd.Env = []string{"GOMAXPROCS=1", "GOMEMLIMIT=24MiB", "PATH=/usr/bin:/bin"}
	cmd.Dir = "/"
	cmd.SysProcAttr = &syscall.SysProcAttr{Credential: &syscall.Credential{Uid: uid, Gid: gid, Groups: []uint32{}}}
	stdin, err1 := cmd.StdinPipe()
	stdout, err2 := cmd.StdoutPipe()
	errb := &capBuf{}
	cmd.Stderr = errb
	if err1 != nil || err2 != nil {
		f.Close()
		os.Remove(path)
		return errors.New("could not start the studio's helper")
	}
	if err := cmd.Start(); err != nil {
		f.Close()
		os.Remove(path)
		return errors.New("could not start the studio's helper: " + err.Error())
	}
	f.Close()
	ready := make(chan string, 1)
	go func() {
		sc := bufio.NewScanner(stdout)
		for sc.Scan() {
			l := sc.Text()
			switch {
			case strings.HasPrefix(l, "ready code="):
				select {
				case ready <- l:
				default:
				}
			case strings.HasPrefix(l, "backend pid="):
				if pid, err := strconv.Atoi(strings.TrimPrefix(l, "backend pid=")); err == nil && pid > 0 && sp.Lower != nil {
					sp.Lower(h.App, pid)
				}
			}
		}
	}()
	done := make(chan struct{})
	go func() {
		cmd.Wait()
		os.Remove(path)
		close(done)
	}()
	var once sync.Once
	h.Done = done
	h.Stop = func() {
		once.Do(func() {
			stdin.Close()
			select {
			case <-done:
			case <-time.After(5 * time.Second):
				cmd.Process.Kill()
			}
		})
	}
	h.Dial = func(ctx context.Context) (net.Conn, error) {
		var d net.Dialer
		return d.DialContext(ctx, "unix", path)
	}
	var line string
	select {
	case line = <-ready:
	case <-done:
		if m := errb.last(); m != "" {
			return errors.New(m)
		}
		return errors.New("the studio's helper for " + h.App + " stopped at once")
	case <-time.After(20 * time.Second):
		h.Stop()
		return errors.New("the studio's helper for " + h.App + " did not start within 20 s")
	}
	code := ""
	for _, w := range strings.Fields(line) {
		if v, ok := strings.CutPrefix(w, "code="); ok {
			code = v
		}
	}
	tok, err := helperToken(h, code)
	if err != nil {
		h.Stop()
		return err
	}
	h.Token = tok
	return nil
}

// helperToken trades the helper's one-time code for its token, as the page would
func helperToken(h *studio.Helper, code string) (string, error) {
	c := &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) { return h.Dial(ctx) }}}
	req, _ := http.NewRequest("POST", "http://studio/api/session", bytes.NewReader([]byte(`{"code":"`+code+`"}`)))
	req.Host = "127.0.0.1:" + strconv.Itoa(h.Port)
	req.Header.Set("Content-Type", "application/json")
	r, err := c.Do(req)
	if err != nil {
		return "", errors.New("the studio's helper did not answer")
	}
	defer r.Body.Close()
	var t struct{ Token string }
	if r.StatusCode != 200 || json.NewDecoder(r.Body).Decode(&t) != nil || t.Token == "" {
		return "", errors.New("the studio's helper refused its own code")
	}
	return t.Token, nil
}

// LowerFile: the request for the root agent (a path unit runs `tando-agent db-studio-lower`):
// an empty file Run/lower/<app>.<pid>. Never trusted there: the agent checks the pid.
func LowerFile(run string) func(app string, pid int) {
	return func(app string, pid int) {
		d := filepath.Join(run, "lower")
		if os.MkdirAll(d, 0o700) != nil {
			return
		}
		os.WriteFile(filepath.Join(d, app+"."+strconv.Itoa(pid)), nil, 0o600)
	}
}
