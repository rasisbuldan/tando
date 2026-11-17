package gate

import (
	"os"
	"syscall"
)

// chmodDir sets the mode of the directory path itself, refusing a symlink there.
func chmodDir(path string, mode uint32) error {
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err == syscall.EACCES {
		// the deploy user's own incoming/ left at mode 000 by an upload (rx mode): it cannot
		// open it, but may change its mode; incoming/'s parent is root's, so the path cannot
		// be swapped for a link
		var st syscall.Stat_t
		if syscall.Lstat(path, &st) == nil && st.Mode&syscall.S_IFMT == syscall.S_IFDIR {
			return syscall.Chmod(path, mode)
		}
	}
	if err != nil {
		return err
	}
	defer syscall.Close(fd)
	return syscall.Fchmod(fd, mode)
}

// ownerOf is the owner of path itself (lstat).
func ownerOf(path string) (uint32, error) {
	var st syscall.Stat_t
	if err := syscall.Lstat(path, &st); err != nil {
		return 0, err
	}
	return st.Uid, nil
}

// ownerUID is the owner of a FileInfo (-1 when unknown).
func ownerUID(fi os.FileInfo) int {
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		return int(st.Uid)
	}
	return -1
}
