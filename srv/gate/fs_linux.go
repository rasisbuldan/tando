//go:build linux

package gate

import (
	"errors"
	"io"
	"os"
	"strings"
	"syscall"
	"unsafe"
)

// Walking a tree that another user may be changing, as root, safely: every directory is opened
// relative to its parent's descriptor with O_NOFOLLOW|O_DIRECTORY, every entry is looked at with
// fstatat(AT_SYMLINK_NOFOLLOW) relative to its directory, links are read with readlinkat, and
// changes (unlink, chown, chmod) are made relative to the directory descriptor on the name just
// checked. A directory swapped for a symlink between the listing and the open is not entered
// (ELOOP/ENOTDIR), so nothing outside the tree is ever reached, whatever path the swap points
// at; an entry that vanished is skipped. The walk does not leave the top's file system (-xdev).

const (
	oDir   = syscall.O_RDONLY | syscall.O_DIRECTORY | syscall.O_NOFOLLOW | syscall.O_CLOEXEC
	atNoFl = 0x100 // AT_SYMLINK_NOFOLLOW
	atRmd  = 0x200 // AT_REMOVEDIR
)

func fstatat(dfd int, name string, st *syscall.Stat_t) error {
	p, err := syscall.BytePtrFromString(name)
	if err != nil {
		return err
	}
	_, _, e := syscall.Syscall6(sysFstatat, uintptr(dfd), uintptr(unsafe.Pointer(p)), uintptr(unsafe.Pointer(st)), atNoFl, 0, 0)
	if e != 0 {
		return e
	}
	return nil
}

func readlinkat(dfd int, name string) (string, error) {
	p, err := syscall.BytePtrFromString(name)
	if err != nil {
		return "", err
	}
	buf := make([]byte, 4096)
	n, _, e := syscall.Syscall6(syscall.SYS_READLINKAT, uintptr(dfd), uintptr(unsafe.Pointer(p)), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)), 0, 0)
	if e != 0 {
		return "", e
	}
	return string(buf[:n]), nil
}

func unlinkat(dfd int, name string, dir bool) error {
	p, err := syscall.BytePtrFromString(name)
	if err != nil {
		return err
	}
	fl := 0
	if dir {
		fl = atRmd
	}
	_, _, e := syscall.Syscall(syscall.SYS_UNLINKAT, uintptr(dfd), uintptr(unsafe.Pointer(p)), uintptr(fl))
	if e != 0 {
		return e
	}
	return nil
}

// walkEnt is one entry during a walk; dfd is its directory (valid during the callback only).
type walkEnt struct {
	dfd  int
	name string
	node
	dev uint64
	ino uint64
}

// walkOpt: links reads symlink targets. own is for walks the deploy user makes of its own upload
// (rx mode): a directory of its own that it cannot enter or change (rsync -p gives it the
// client's mode, 000 too) is first given u+rwx, and one it still cannot open is skipped, so a
// mode cannot hide links or setuid files from the walk (the shell's find went on past them).
// Root's walks (scan, watchdog) need neither: root reads every directory, and an error ends the
// walk, which refuses the upload.
type walkOpt struct{ links, own bool }

// walkTree calls pre for top (rel "") and for every entry below it, parents first, and post
// (if not nil) for every entry below the top, children first.
func walkTree(top string, links bool, pre, post func(*walkEnt) error) error {
	return walkTreeOpt(top, walkOpt{links: links}, pre, post)
}

func walkTreeOpt(top string, o walkOpt, pre, post func(*walkEnt) error) error {
	fd, err := syscall.Open(top, oDir, 0)
	if err != nil {
		return err
	}
	defer syscall.Close(fd)
	var st syscall.Stat_t
	if err := syscall.Fstat(fd, &st); err != nil {
		return err
	}
	e := walkEnt{dfd: -1, node: nodeOf("", &st), dev: uint64(st.Dev), ino: st.Ino}
	if err := pre(&e); err != nil {
		return stopOK(err)
	}
	return stopOK(walkDir(fd, "", uint64(st.Dev), o, pre, post))
}

func stopOK(err error) error {
	if errors.Is(err, errStop) {
		return nil
	}
	return err
}

func nodeOf(rel string, st *syscall.Stat_t) node {
	return node{rel: rel, mode: st.Mode, uid: st.Uid, nlink: uint64(st.Nlink), size: st.Size}
}

func walkDir(dfd int, rel string, dev uint64, o walkOpt, pre, post func(*walkEnt) error) error {
	nfd, err := syscall.Dup(dfd)
	if err != nil {
		return err
	}
	syscall.CloseOnExec(nfd)
	f := os.NewFile(uintptr(nfd), "dir")
	defer f.Close()
	for {
		names, rerr := f.Readdirnames(512)
		for _, name := range names {
			if err := walkOne(dfd, rel, name, dev, o, pre, post); err != nil {
				return err
			}
		}
		if rerr == io.EOF {
			return nil
		}
		if rerr != nil {
			if gone(rerr) {
				return nil
			}
			return rerr
		}
	}
}

func walkOne(dfd int, rel, name string, dev uint64, o walkOpt, pre, post func(*walkEnt) error) error {
	var st syscall.Stat_t
	if err := fstatat(dfd, name, &st); err != nil {
		if gone(err) {
			return nil
		}
		return err
	}
	r := name
	if rel != "" {
		r = rel + "/" + name
	}
	e := walkEnt{dfd: dfd, name: name, node: nodeOf(r, &st), dev: uint64(st.Dev), ino: st.Ino}
	if o.links && e.isLink() {
		t, err := readlinkat(dfd, name)
		if err != nil && !gone(err) {
			return err
		}
		e.target = t
	}
	if err := pre(&e); err != nil {
		return err
	}
	if e.isDir() && uint64(st.Dev) == dev {
		if o.own && int(st.Uid) == os.Geteuid() && st.Mode&0o700 != 0o700 {
			// (fchmodat follows a symlink only at name, which fstatat just saw as a directory of
			// this user; a swap can only be the user's own, in its own sandbox)
			syscall.Fchmodat(dfd, name, st.Mode&0o7777|0o700, 0)
		}
		cfd, err := syscall.Openat(dfd, name, oDir, 0)
		switch {
		case err == nil:
			var cst syscall.Stat_t
			if err := syscall.Fstat(cfd, &cst); err == nil && cst.Ino == st.Ino && uint64(cst.Dev) == uint64(st.Dev) {
				err = walkDir(cfd, r, dev, o, pre, post)
				syscall.Close(cfd)
				if err != nil {
					return err
				}
			} else {
				syscall.Close(cfd) // swapped since the fstatat: not this directory
			}
		case gone(err):
		case o.own && (errors.Is(err, syscall.EACCES) || errors.Is(err, syscall.EPERM)):
		default:
			return err
		}
	}
	if post != nil {
		e.dfd = dfd
		return post(&e)
	}
	return nil
}

// readTree walks top into a tree (with link targets) and feeds every entry to see. It keeps at
// most keep entries below the top (the rest are only seen): a tree over the limit is refused
// anyway, and memory stays bounded.
func readTree(top string, keep int64, see func(*node)) (*tree, bool, error) {
	return readTreeOpt(top, walkOpt{links: true}, keep, see)
}

// readOwnTree is readTree for the deploy user's walk of its own upload (walkOpt.own).
func readOwnTree(top string, keep int64) (*tree, error) {
	t, _, err := readTreeOpt(top, walkOpt{links: true, own: true}, keep, func(*node) {})
	return t, err
}

func readTreeOpt(top string, o walkOpt, keep int64, see func(*node)) (*tree, bool, error) {
	t := newTree(top)
	var n int64
	over := false
	err := walkTreeOpt(top, o, func(e *walkEnt) error {
		nd := e.node
		see(&nd)
		if nd.rel != "" {
			if n++; n > keep {
				over = true
				return nil
			}
		}
		t.add(&nd)
		return nil
	}, nil)
	return t, over, err
}

// measure counts the entries (the top included) and their bytes, stopping as soon as either
// passes its limit (the watchdog needs no more).
func measure(top string, maxBytes, maxN int64) (bytes, n int64, err error) {
	err = walkTree(top, false, func(e *walkEnt) error {
		bytes += e.size
		n++
		if bytes > maxBytes || n > maxN {
			return errStop
		}
		return nil
	}, nil)
	return bytes, n, err
}

// openDirAt opens the directory rel below top, every component with O_NOFOLLOW.
func openDirAt(top, rel string) (int, error) {
	fd, err := syscall.Open(top, oDir, 0)
	if err != nil {
		return -1, err
	}
	if rel == "" || rel == "." {
		return fd, nil
	}
	for c := range strings.SplitSeq(rel, "/") {
		nfd, err := syscall.Openat(fd, c, oDir, 0)
		syscall.Close(fd)
		if err != nil {
			return -1, err
		}
		fd = nfd
	}
	return fd, nil
}

// unlinkLink removes the symlink at rel below top, if it is still a symlink.
func unlinkLink(top, rel string) error {
	dir, name := "", rel
	if i := strings.LastIndexByte(rel, '/'); i >= 0 {
		dir, name = rel[:i], rel[i+1:]
	}
	fd, err := openDirAt(top, dir)
	if err != nil {
		return err
	}
	defer syscall.Close(fd)
	var st syscall.Stat_t
	if err := fstatat(fd, name, &st); err != nil {
		return err
	}
	if st.Mode&syscall.S_IFMT != syscall.S_IFLNK {
		return nil
	}
	return unlinkat(fd, name, false)
}

// chownTree gives top and everything below it to uid:gid, links themselves (chown -RhP).
func chownTree(top string, uid, gid int) error {
	return walkTree(top, false, func(e *walkEnt) error {
		if e.rel == "" {
			fd, err := syscall.Open(top, oDir, 0)
			if err != nil {
				return err
			}
			defer syscall.Close(fd)
			return syscall.Fchown(fd, uid, gid)
		}
		if err := syscall.Fchownat(e.dfd, e.name, uid, gid, atNoFl); err != nil && !gone(err) {
			return err
		}
		return nil
	}, nil)
}

// stripSetid removes setuid and setgid bits from the regular files below top (chmod ug-s), as
// the deploy user over its own upload; a file it cannot change does not stop the rest.
func stripSetid(top string) error {
	var first error
	err := walkTreeOpt(top, walkOpt{own: true}, func(e *walkEnt) error {
		if e.rel != "" && e.isReg() && e.mode&0o6000 != 0 {
			if err := syscall.Fchmodat(e.dfd, e.name, e.mode&0o7777&^0o6000, 0); err != nil && !gone(err) && first == nil {
				first = err
			}
		}
		return nil
	}, nil)
	if err != nil {
		return err
	}
	return first
}

// removeOwned deletes every entry below top owned by uid, children first (find -xdev -mindepth 1
// -uid <uid> -delete); a directory that still holds others' files stays. Errors are ignored.
func removeOwned(top string, uid uint32) {
	walkTree(top, false, func(*walkEnt) error { return nil }, func(e *walkEnt) error {
		if e.uid == uid {
			unlinkat(e.dfd, e.name, e.isDir())
		}
		return nil
	})
}
