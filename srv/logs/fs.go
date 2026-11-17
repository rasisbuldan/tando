package logs

import (
	"errors"
	"fmt"
	"hash/crc32"
	"io/fs"
	"os"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"tando/srv/internal/atomicfile"
	"tando/srv/internal/fsinfo"
)

// Users looks up the ids tando-logs gives files to (caddy, tando-<app>, adm).
type Users interface {
	UID(name string) (int, error)
	GID(name string) (int, error)
}

// OSUsers reads /etc/passwd and /etc/group (os/user without cgo).
type OSUsers struct{}

// UID implements Users.
func (OSUsers) UID(name string) (int, error) {
	u, err := user.Lookup(name)
	if err != nil {
		return -1, err
	}
	return strconv.Atoi(u.Uid)
}

// GID implements Users.
func (OSUsers) GID(name string) (int, error) {
	g, err := user.LookupGroup(name)
	if err != nil {
		return -1, err
	}
	return strconv.Atoi(g.Gid)
}

// root: the ids of root:root (what the shell's install -o root -g root and chown root:root gave).
func (l *Logs) root() (uid, gid int) {
	uid, err1 := l.Users.UID("root")
	gid, err2 := l.Users.GID("root")
	if err1 != nil || err2 != nil {
		return 0, 0
	}
	return uid, gid
}

func (l *Logs) rootPerm(mode fs.FileMode) atomicfile.Perm {
	uid, gid := l.root()
	return atomicfile.Perm{Mode: mode, UID: uid, GID: gid}
}

// ensureDir is `install -d -m mode -o uid -g gid`: the directory is created when missing, and
// gets the mode and owner either way (uid/gid -1: unchanged). A symlink or another kind of file
// in its place is an error, not followed.
func ensureDir(p string, mode fs.FileMode, uid, gid int) error {
	fi, err := os.Lstat(p)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		// missing parents too, as install -d (they get 755 from the umask)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			return err
		}
		if err := os.Mkdir(p, 0o700); err != nil && !errors.Is(err, fs.ErrExist) {
			return err
		}
	case err != nil:
		return err
	case !fi.IsDir():
		return fmt.Errorf("%s is not a directory", p)
	}
	if uid >= 0 || gid >= 0 {
		if err := os.Lchown(p, uid, gid); err != nil {
			return err
		}
	}
	// after the chown, which may clear the setgid bit
	return os.Chmod(p, mode)
}

// ownFile gives an existing regular file its owner and mode without following a symlink (the
// directories it is used in are writable by Caddy, which could swap a file for a link).
func ownFile(p string, mode fs.FileMode, uid, gid int) error {
	f, err := os.OpenFile(p, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return err
	}
	if !fi.Mode().IsRegular() {
		return fmt.Errorf("%s is not a regular file", p)
	}
	// a hard link to another file (made by whoever can write the directory) is not given away
	if st, ok := fi.Sys().(*syscall.Stat_t); ok && st.Nlink != 1 {
		return fmt.Errorf("%s has %d links", p, st.Nlink)
	}
	if err := f.Chown(uid, gid); err != nil {
		return err
	}
	return f.Chmod(mode)
}

// createFile makes an empty file with the mode and owner when nothing is there (the shell's
// `[[ -f f ]] || install -m mode -o u -g g /dev/null f`).
func createFile(p string, mode fs.FileMode, uid, gid int) error {
	if _, err := os.Lstat(p); err == nil {
		return nil
	}
	f, err := os.OpenFile(p, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	if uid >= 0 || gid >= 0 {
		if err := f.Chown(uid, gid); err != nil {
			return err
		}
	}
	return f.Chmod(mode)
}

// diskUsage is `du -sB1 p`: the allocated bytes of p and everything under it, directories
// included, a file with several links once, symlinks not followed. The request log's directory
// is Caddy's, so the walk is fd-relative (os.Root: each level opened from its parent's open
// directory, never by a path an intermediate swap could redirect outside p; a FIFO in place of a
// directory fails the open, it does not hang it) and bounded: duMaxEntries entries, duMaxDepth
// levels, duMaxTime, duMaxLinks hard-linked files remembered. Past a bound the total so far is
// returned: a lower bound, never unbounded work.
func diskUsage(p string) (int64, error) {
	r, err := os.OpenRoot(p)
	if err != nil {
		return 0, err
	}
	defer r.Close()
	w := duWalk{seen: map[[2]uint64]bool{}, until: time.Now().Add(duMaxTime)}
	w.walk(r, 0)
	return w.total, nil
}

const (
	duMaxEntries = 200000
	duMaxDepth   = 32
	duMaxLinks   = 10000
	duMaxTime    = 2 * time.Second
)

type duWalk struct {
	seen    map[[2]uint64]bool
	total   int64
	entries int
	until   time.Time
}

func (w *duWalk) stop() bool { return w.entries >= duMaxEntries || time.Now().After(w.until) }

func (w *duWalk) walk(r *os.Root, depth int) {
	d, err := r.Open(".")
	if err != nil {
		return
	}
	defer d.Close()
	if fi, err := d.Stat(); err == nil {
		w.total += blocks(fi)
	}
	for !w.stop() {
		ents, err := d.ReadDir(512)
		for _, e := range ents {
			w.entries++
			if w.stop() {
				return
			}
			fi, err := r.Lstat(e.Name())
			if err != nil {
				continue // du goes on past an unreadable entry
			}
			if fi.IsDir() {
				if depth < duMaxDepth {
					if sub, err := r.OpenRoot(e.Name()); err == nil {
						w.walk(sub, depth+1)
						sub.Close()
					}
				}
				continue
			}
			if st, ok := fi.Sys().(*syscall.Stat_t); ok && st.Nlink > 1 {
				k := [2]uint64{uint64(st.Dev), uint64(st.Ino)}
				if w.seen[k] {
					continue
				}
				if len(w.seen) < duMaxLinks {
					w.seen[k] = true
				}
			}
			w.total += blocks(fi)
		}
		if err != nil || len(ents) == 0 {
			return
		}
	}
}

func blocks(fi fs.FileInfo) int64 {
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		return int64(st.Blocks) * 512
	}
	return fi.Size()
}

// diskKB is `df -Pk p`: the file system's size and the space available to non-root, in KiB.
func diskKB(p string) (total, avail int64, err error) {
	fs, err := fsinfo.Statfs(p)
	if err != nil {
		return 0, 0, err
	}
	return int64(fs.KiB(fs.Blocks)), int64(fs.KiB(fs.Avail)), nil
}

// writeNoSync replaces p atomically (a temporary file in the same directory, renamed over it)
// without flushing it to disk: for bookkeeping that is rebuilt or re-read when a crash loses it
// (the request index's state, the scan's positions), written every minute by a busy app.
func writeNoSync(p string, data []byte, mode fs.FileMode) error {
	f, err := os.CreateTemp(filepath.Dir(p), "."+filepath.Base(p)+".tmp*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	_, err = f.Write(data)
	if err == nil {
		err = f.Chmod(mode)
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp, p)
	}
	if err != nil {
		os.Remove(tmp)
	}
	return err
}

// writeInPlace overwrites p with data (created when missing): one open, one write, a truncate.
// For the small bookkeeping files a scan updates every minute (the index's state, positions,
// stamps, the journal cursor), where a replace by rename costs more than all the rest of a busy
// app's scan (on overlayfs most of all). A crash or a reader at the wrong moment can see a torn
// file; each reader treats one as missing: the index is rebuilt from the log, the scan starts
// over from the end, a stamp or position is taken again.
func writeInPlace(p string, data []byte, mode fs.FileMode) error {
	f, err := os.OpenFile(p, os.O_WRONLY|os.O_CREATE|syscall.O_NOFOLLOW, mode)
	if err != nil {
		return err
	}
	_, err = f.WriteAt(data, 0)
	if err == nil {
		err = f.Truncate(int64(len(data)))
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}

// sealed: text followed by a line "sum <crc32>" of it, so that a file written in place and read
// torn (a crash, a reader between the write and the truncate) is seen as torn.
func sealed(text string) string {
	return text + "sum " + strconv.FormatUint(uint64(crc32.ChecksumIEEE([]byte(text))), 16) + "\n"
}

// unseal: the text of a sealed file; ok is false when it is not whole (or not sealed).
func unseal(b []byte) (string, bool) {
	s := string(b)
	i := strings.LastIndex(strings.TrimSuffix(s, "\n"), "\n")
	if i < 0 || !strings.HasSuffix(s, "\n") || !strings.HasPrefix(s[i+1:], "sum ") {
		return "", false
	}
	text := s[:i+1]
	return text, strings.TrimSuffix(s[i+1:], "\n") == "sum "+strconv.FormatUint(uint64(crc32.ChecksumIEEE([]byte(text))), 16)
}

// openRegular opens a file of a directory someone else can write (the request log's is Caddy's)
// for reading: no symlink followed, no blocking open (a FIFO swapped in after a stat would hang
// the caller), and it must be a regular file once open (fstat).
func openRegular(p string) (*os.File, error) {
	f, err := os.OpenFile(p, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	if fi, err := f.Stat(); err != nil || !fi.Mode().IsRegular() {
		f.Close()
		return nil, fmt.Errorf("%s: not a regular file", p)
	}
	return f, nil
}

// openDir opens a directory to list it the same way: no symlink, no FIFO.
func openDir(p string) (*os.File, error) {
	fd, err := syscall.Open(p, syscall.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, &os.PathError{Op: "open", Path: p, Err: err}
	}
	return os.NewFile(uintptr(fd), p), nil
}
