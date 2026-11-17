package logs

// The request log's files as the index sees them: the list (oldest first), a file's identity
// across Caddy's roll and gzip (its first line), its uncompressed bytes, and the two file
// operations the index's crash safety rests on (one write per append, truncation to the state).

import (
	"bufio"
	"compress/gzip"
	"errors"
	"fmt"
	"hash/fnv"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"syscall"
)

type logFile struct {
	name, path string
	ino        uint64
	size       int64
	mtime      int64
	gz         bool
	meta       *fileMeta
}

// The request log's directory is Caddy's: anything running as caddy can put files there. Only
// names of Caddy's own roll pattern count (access.log, access-<time>.log[.gz]: letters, digits
// and ._:+-, at most 100 of them), so a name never carries a blank or a newline into the index's
// state; and what is read of the directory is bounded: at most maxDirEntries entries, of which the
// maxLogFiles newest log files by name (Caddy keeps roll_keep of them, at most 99). More is not a
// request log tando set up: it is reported (log-doctor, the audit trail), never worked through.
var reLogName = regexp.MustCompile(`^access(-[A-Za-z0-9._:+-]{1,100})?\.log(\.gz)?$`)

const (
	maxLogFiles   = 1000
	maxDirEntries = 20000
)

// logNames: the request log's file names in dir (access.log first when there), at most
// maxLogFiles, the newest rolled ones by name; over counts what was left out (or the entries not
// read past maxDirEntries).
func logNames(dir string) (names []string, over int) {
	d, err := openDir(dir)
	if err != nil {
		return nil, 0
	}
	defer d.Close()
	current := false
	read := 0
	trim := func() {
		if len(names) > maxLogFiles {
			sort.Sort(sort.Reverse(sort.StringSlice(names)))
			over += len(names) - maxLogFiles
			names = names[:maxLogFiles]
		}
	}
	for read < maxDirEntries {
		ents, err := d.ReadDir(512)
		read += len(ents)
		for _, e := range ents {
			n := e.Name()
			switch {
			case n == "access.log":
				current = true
			case reLogName.MatchString(n):
				names = append(names, n)
				if len(names) >= 2*maxLogFiles {
					trim()
				}
			}
		}
		if err != nil || len(ents) == 0 {
			break
		}
	}
	if read >= maxDirEntries {
		if more, _ := d.ReadDir(1); len(more) > 0 {
			over++
		}
	}
	trim()
	if current {
		names = append([]string{"access.log"}, names...)
	}
	return names, over
}

// listLog: the request log's files (regular, not symlinks), oldest first by mtime.
func (a *app) listLog() []*logFile {
	_, as := a.cached()
	dir := a.logDir()
	names, over := logNames(dir)
	a.l.tooManyLogFiles(a, over)
	var fs []*logFile
	for _, n := range names {
		p := filepath.Join(dir, n)
		fi, err := os.Lstat(p)
		if err != nil || !fi.Mode().IsRegular() {
			continue
		}
		f := &logFile{name: n, path: p, size: fi.Size(), mtime: fi.ModTime().Unix()}
		if st, ok := fi.Sys().(*syscall.Stat_t); ok {
			f.ino = uint64(st.Ino)
		}
		// what a file is (gzip or not, its first line) stays while its inode does and it does not
		// shrink: known once, not read again every minute
		m := as.files[n]
		if m == nil || m.ino != f.ino || f.size < m.size {
			m = &fileMeta{ino: f.ino, gz: isGzip(p), fp: ""}
			as.files[n] = m
		}
		m.size = f.size
		f.gz, f.meta = m.gz, m
		fs = append(fs, f)
	}
	sort.Slice(fs, func(i, j int) bool {
		return fs[i].mtime < fs[j].mtime || fs[i].mtime == fs[j].mtime && fs[i].name < fs[j].name
	})
	if len(as.files) > len(fs) { // files Caddy deleted: forgotten
		here := make(map[string]bool, len(fs))
		for _, f := range fs {
			here[f.name] = true
		}
		for n := range as.files {
			if !here[n] {
				delete(as.files, n)
			}
		}
	}
	return fs
}

func isGzip(p string) bool {
	f, err := openRegular(p)
	if err != nil {
		return false
	}
	defer f.Close()
	var m [2]byte
	n, _ := f.ReadAt(m[:], 0)
	return n == 2 && m[0] == 0x1f && m[1] == 0x8b
}

// fingerprint: a hash of a file's first line (at most 4 KiB of it), which a file keeps when Caddy
// renames and gzips it; "-" when it has no complete first line yet.
func fingerprint(f *logFile) string {
	if f.meta != nil && f.meta.fp != "" && f.meta.fp != "-" {
		return f.meta.fp
	}
	fp := readFingerprint(f)
	if f.meta != nil {
		f.meta.fp = fp
	}
	return fp
}

func readFingerprint(f *logFile) string {
	r, closer, err := openLog(f)
	if err != nil {
		return "-"
	}
	defer closer()
	br := bufio.NewReaderSize(r, 4096)
	line, err := br.ReadSlice('\n')
	if err != nil && err != bufio.ErrBufferFull {
		return "-"
	}
	h := fnv.New64a()
	h.Write(line)
	return strconv.FormatUint(h.Sum64(), 16)
}

// openLog: the file's uncompressed bytes.
func openLog(f *logFile) (io.Reader, func(), error) {
	fd, err := openRegular(f.path)
	if err != nil {
		return nil, nil, err
	}
	if !f.gz {
		return io.NewSectionReader(fd, 0, f.size), func() { fd.Close() }, nil
	}
	z, err := gzip.NewReader(bufio.NewReaderSize(fd, 64<<10))
	if err != nil {
		fd.Close()
		return nil, nil, err
	}
	return z, func() { fd.Close() }, nil
}

// openFrom opens a log file's uncompressed bytes at off; false when it is gone, or a gzip file
// that does not reach off yet (still being written).
func openFrom(f *logFile, off int64) (io.Reader, func(), bool) {
	r, closer, err := openLog(f)
	if err != nil {
		return nil, nil, false
	}
	if f.gz {
		if _, err := io.CopyN(io.Discard, r, off); err != nil {
			closer()
			return nil, nil, false
		}
		return r, closer, true
	}
	return io.NewSectionReader(r.(*io.SectionReader), off, f.size-off), closer, true
}

func appendFile(p string, b []byte) error {
	f, err := os.OpenFile(p, os.O_WRONLY|os.O_APPEND|os.O_CREATE|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return err
	}
	_, err = f.Write(b)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}

func truncateTo(p string, n int64) error {
	fi, err := os.Lstat(p)
	if errors.Is(err, os.ErrNotExist) {
		if n == 0 {
			return nil
		}
		return fmt.Errorf("%s: missing", p)
	}
	if err != nil {
		return err
	}
	if fi.Size() < n {
		return fmt.Errorf("%s: %d bytes, want %d", p, fi.Size(), n)
	}
	if fi.Size() > n {
		return os.Truncate(p, n)
	}
	return nil
}
