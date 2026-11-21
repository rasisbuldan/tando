package dash

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
)

// MinTando: the oldest tando CLI tando-dash works with. The real gate is the `snapshot`
// command (probed with `tando help snapshot`); bump this to the release that ships it.
const MinTando = "0.2.2"

// Guard: refuses the tando CLI when it is older than Min or has no `snapshot` (review S6), and
// checks again when the file changes on disk (an upgrade underneath tando-dash).
type Guard struct {
	Min   string
	Run   func(ctx context.Context, argv []string) (Result, error)
	Stamp func() string // what identifies the CLI on disk now (size, mtime, inode)

	mu      sync.Mutex
	checked bool
	stamp   string
	err     error
	version string
}

// Check: nil when the CLI is fine; cheap (one stat) while the CLI does not change
func (g *Guard) Check(ctx context.Context) error {
	st := g.Stamp()
	g.mu.Lock()
	if g.checked && st == g.stamp {
		err := g.err
		g.mu.Unlock()
		return err
	}
	g.mu.Unlock()
	v, err := g.probe(ctx)
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) || errors.Is(err, ErrBusy) {
		return err
	}
	g.mu.Lock()
	g.checked, g.stamp, g.err, g.version = true, st, err, v
	g.mu.Unlock()
	return err
}

// Version: what the last check found
func (g *Guard) Version() string {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.version
}

func (g *Guard) probe(ctx context.Context) (string, error) {
	res, err := g.Run(ctx, []string{"--version"})
	if err != nil {
		if ctx.Err() != nil {
			return "", ctx.Err()
		}
		return "", fmt.Errorf("update tando: `tando --version` failed (%v)", err)
	}
	v := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(string(res.Stdout)), "tando "))
	if f := strings.Fields(v); len(f) > 0 {
		v = f[0]
	}
	if _, ok := parseVer(v); !ok {
		return "", fmt.Errorf("update tando: cannot read the version of this tando (%q); tando-dash needs %s or later", firstLine(string(res.Stdout)), g.Min)
	}
	if older(v, g.Min) {
		return v, fmt.Errorf("update tando: this tando is %s, tando-dash needs %s or later (tando update)", v, g.Min)
	}
	if _, err := g.Run(ctx, []string{"help", "snapshot"}); err != nil {
		if ctx.Err() != nil {
			return v, ctx.Err()
		}
		return v, fmt.Errorf("update tando: tando %s has no `snapshot` command, which tando-dash reads everything with (tando update)", v)
	}
	return v, nil
}

func parseVer(s string) ([3]int, bool) {
	var out [3]int
	s, _, _ = strings.Cut(s, "-")
	p := strings.Split(s, ".")
	if len(p) != 3 {
		return out, false
	}
	for i, x := range p {
		n, err := strconv.Atoi(x)
		if err != nil || n < 0 {
			return out, false
		}
		out[i] = n
	}
	return out, true
}

func older(a, b string) bool {
	x, _ := parseVer(a)
	y, _ := parseVer(b)
	for i := 0; i < 3; i++ {
		if x[i] != y[i] {
			return x[i] < y[i]
		}
	}
	return false
}

// FileStamp: size, mtime and inode of path ("" when it is gone)
func FileStamp(path string) string {
	fi, err := os.Stat(path)
	if err != nil {
		return ""
	}
	ino := uint64(0)
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		ino = uint64(st.Ino)
	}
	return fmt.Sprintf("%d-%d-%d", fi.Size(), fi.ModTime().UnixNano(), ino)
}

// FindTando: the tando CLI to run, like the menu bar finds it: --tando, TANDO_DASH_TANDO, the
// menu bar's setting (menubar.conf tando=), PATH, then the usual install places
func FindTando(flag, cfgDir string) string {
	for _, p := range []string{flag, os.Getenv("TANDO_DASH_TANDO"), menubarTando(cfgDir)} {
		if p != "" {
			return p
		}
	}
	if p, err := exec.LookPath("tando"); err == nil {
		if a, err := filepath.Abs(p); err == nil {
			return a
		}
	}
	home, _ := os.UserHomeDir()
	for _, p := range []string{filepath.Join(home, ".local/bin/tando"), "/usr/local/bin/tando", "/opt/homebrew/bin/tando"} {
		if fi, err := os.Stat(p); err == nil && fi.Mode()&0o111 != 0 {
			return p
		}
	}
	return ""
}

func menubarTando(cfgDir string) string {
	f, err := os.Open(filepath.Join(cfgDir, "menubar.conf"))
	if err != nil {
		return ""
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		if v, ok := strings.CutPrefix(strings.TrimSpace(sc.Text()), "tando="); ok && filepath.IsAbs(v) {
			return v
		}
	}
	return ""
}
