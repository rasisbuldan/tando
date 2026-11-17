package offsite

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"syscall"
)

// Files root reads for an upload, and its own settings, are opened without following a link
// (O_NOFOLLOW), without blocking on a FIFO (O_NONBLOCK), and accepted only when they are regular
// files owned by the expected user (root on a server): an app can neither point root at another
// file nor feed it one of its own. The backup directories are root's 700 anyway; the app's
// app.conf and env are root's files in a root directory.

func isNotExist(err error) bool { return errors.Is(err, fs.ErrNotExist) }

// openOwned opens path for reading under those rules.
func openOwned(path string, uid int) (*os.File, os.FileInfo, error) {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		if errors.Is(err, syscall.ELOOP) {
			return nil, nil, fmt.Errorf("%s is a symbolic link: refused", path)
		}
		return nil, nil, err
	}
	fi, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, nil, err
	}
	if !fi.Mode().IsRegular() {
		f.Close()
		return nil, nil, fmt.Errorf("%s is not a regular file: refused", path)
	}
	if st, ok := fi.Sys().(*syscall.Stat_t); ok && int(st.Uid) != uid {
		f.Close()
		return nil, nil, fmt.Errorf("%s is not owned by uid %d: refused", path, uid)
	}
	return f, fi, nil
}

// readRootFile reads a whole small file under those rules (at most max bytes).
func readRootFile(path string, max int64, uid int) ([]byte, error) {
	f, fi, err := openOwned(path, uid)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	if fi.Size() > max {
		return nil, fmt.Errorf("%s is larger than %d bytes: refused", path, max)
	}
	return io.ReadAll(io.LimitReader(f, max))
}
