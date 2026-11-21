// tando-dash: the tando dashboard's local server (addons/dashboard). It serves the web app on
// 127.0.0.1 and an API that runs only the tando CLI, from a fixed allowlist of argv shapes.
//
//	tando-dash [--no-open] [--idle 30m] [--port N] [--tando PATH]
//
// A second tando-dash reuses the running one (dash.lock) and opens a fresh link to it.
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"tando-dash/internal/dash"
	"tando-dash/webdist"
)

var version = "dev" // -ldflags "-X main.version=..." (the add-on's VERSION)

func main() {
	os.Exit(run())
}

func run() int {
	noOpen := flag.Bool("no-open", false, "print the link, do not open a browser")
	idle := flag.Duration("idle", 30*time.Minute, "stop after this long without a request (0: never)")
	port := flag.Int("port", 0, "port on 127.0.0.1 (0: the last one if free, else any)")
	tandoFlag := flag.String("tando", "", "the tando CLI to run (default: as the menu bar finds it)")
	showVer := flag.Bool("version", false, "print the version")
	flag.Parse()
	if *showVer {
		fmt.Println("tando-dash " + version)
		return 0
	}
	if flag.NArg() > 0 {
		fmt.Fprintln(os.Stderr, "tando-dash: unexpected argument "+flag.Arg(0))
		return 2
	}
	cfgDir := os.Getenv("TANDO_CONFIG_DIR")
	if cfgDir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			fmt.Fprintln(os.Stderr, "tando-dash: no home directory")
			return 1
		}
		cfgDir = filepath.Join(home, ".config", "tando")
	}

	lock, other, err := dash.AcquireLock(filepath.Join(cfgDir, "dash.lock"))
	if err != nil {
		fmt.Fprintln(os.Stderr, "tando-dash: "+err.Error())
		return 1
	}
	if other != nil {
		return reuse(other, *noOpen)
	}
	defer lock.Release()

	tando := dash.FindTando(*tandoFlag, cfgDir)
	lim := dash.NewLimiter(8, 3, 64)
	runner := &dash.ExecRunner{Path: func() string { return tando }, MaxOut: 8 << 20, Lim: lim,
		Env: []string{"TANDO_COLOR=never"}}
	guard := &dash.Guard{Min: dash.MinTando, Stamp: func() string { return dash.FileStamp(tando) },
		Run: func(ctx context.Context, argv []string) (dash.Result, error) {
			ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
			defer cancel()
			return runner.Run(ctx, dash.Req{Argv: argv})
		}}
	if tando == "" {
		fmt.Fprintln(os.Stderr, "tando-dash: tando not found: install tando, or give --tando PATH")
		return 1
	}
	if err := guard.Check(context.Background()); err != nil {
		fmt.Fprintln(os.Stderr, "tando-dash: "+err.Error())
		return 1
	}

	ln, err := listen(cfgDir, *port)
	if err != nil {
		fmt.Fprintln(os.Stderr, "tando-dash: "+err.Error())
		return 1
	}
	p := ln.Addr().(*net.TCPAddr).Port
	key := randKey()
	srv, err := dash.New(dash.Config{Port: p, ConfigDir: cfgDir, Runner: runner, CtlKey: key, Version: guard},
		webdist.Handler(webdist.FS()))
	if err != nil {
		fmt.Fprintln(os.Stderr, "tando-dash: "+err.Error())
		return 1
	}
	base := "http://127.0.0.1:" + strconv.Itoa(p) + "/"
	if err := lock.Write(dash.LockInfo{Pid: os.Getpid(), Port: p, URL: base, Key: key, Started: time.Now().UTC().Format(time.RFC3339)}); err != nil {
		fmt.Fprintln(os.Stderr, "tando-dash: "+err.Error())
		return 1
	}
	_ = os.WriteFile(filepath.Join(cfgDir, "cache", "dash-port"), []byte(strconv.Itoa(p)+"\n"), 0o600)

	hs := &http.Server{Handler: srv, ReadHeaderTimeout: 10 * time.Second, ReadTimeout: 30 * time.Second,
		IdleTimeout: 120 * time.Second, MaxHeaderBytes: 16 << 10}
	done := make(chan error, 1)
	go func() { done <- hs.Serve(ln) }()

	link := base + "open?code=" + srv.NewCode()
	fmt.Printf("tando-dash %s: %s (tando %s)\n", version, base, guard.Version())
	fmt.Printf("open: %s (works once, for 60 s; run tando-dash again for a new one)\n", link)
	if !*noOpen {
		openBrowser(link)
	}

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	tick := time.NewTicker(30 * time.Second)
	defer tick.Stop()
	why := ""
loop:
	for {
		select {
		case s := <-sig:
			why = s.String()
			break loop
		case err := <-done:
			if err != nil && !errors.Is(err, http.ErrServerClosed) {
				fmt.Fprintln(os.Stderr, "tando-dash: "+err.Error())
				return 1
			}
			return 0
		case <-tick.C:
			if *idle > 0 && time.Since(srv.LastUse()) > *idle && srv.WritesRunning() == 0 {
				why = "idle for " + idle.String()
				break loop
			}
		}
	}
	// graceful: no new requests, the reads' children killed; a write's child keeps running
	// (its own process group, output to a file): tando owns the operation, the page reattaches
	fmt.Printf("tando-dash: stopping (%s)\n", why)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	srv.Close()
	_ = hs.Shutdown(ctx)
	if n := srv.WritesRunning(); n > 0 {
		fmt.Printf("tando-dash: %d write(s) still running; tando finishes them (tando status shows the outcome)\n", n)
	}
	return 0
}

// listen: 127.0.0.1 only; the port asked for, else the last one (a reloaded tab finds it
// again), else any free one
func listen(cfgDir string, port int) (net.Listener, error) {
	if port != 0 {
		return net.Listen("tcp", "127.0.0.1:"+strconv.Itoa(port))
	}
	if b, err := os.ReadFile(filepath.Join(cfgDir, "cache", "dash-port")); err == nil {
		if p, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil && p > 1024 && p < 65536 {
			if ln, err := net.Listen("tcp", "127.0.0.1:"+strconv.Itoa(p)); err == nil {
				return ln, nil
			}
		}
	}
	return net.Listen("tcp", "127.0.0.1:0")
}

// reuse: a tando-dash runs already: ask it for a fresh link
func reuse(li *dash.LockInfo, noOpen bool) int {
	c := &http.Client{Timeout: 5 * time.Second}
	req, _ := http.NewRequest("POST", "http://127.0.0.1:"+strconv.Itoa(li.Port)+"/api/newcode", bytes.NewReader([]byte("{}")))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Tando-Dash-Key", li.Key)
	resp, err := c.Do(req)
	if err != nil {
		fmt.Fprintf(os.Stderr, "tando-dash: one runs already (pid %d) but does not answer: stop it (kill %d), then start again\n", li.Pid, li.Pid)
		return 1
	}
	defer resp.Body.Close()
	var out struct{ Code string }
	if resp.StatusCode != 200 || json.NewDecoder(resp.Body).Decode(&out) != nil || out.Code == "" {
		fmt.Fprintf(os.Stderr, "tando-dash: the running one (pid %d) refused a new link (HTTP %d)\n", li.Pid, resp.StatusCode)
		return 1
	}
	link := "http://127.0.0.1:" + strconv.Itoa(li.Port) + "/open?code=" + out.Code
	fmt.Printf("tando-dash runs already (pid %d): %s\nopen: %s\n", li.Pid, li.URL, link)
	if !noOpen {
		openBrowser(link)
	}
	return 0
}

// openBrowser: the system's opener with the link as one argument (no shell)
func openBrowser(link string) {
	name := "xdg-open"
	if runtime.GOOS == "darwin" {
		name = "/usr/bin/open"
	}
	cmd := exec.Command(name, link)
	if err := cmd.Start(); err != nil {
		fmt.Fprintln(os.Stderr, "tando-dash: could not open a browser ("+err.Error()+"); open the link above")
		return
	}
	go func() { _ = cmd.Wait() }()
}

func randKey() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}
