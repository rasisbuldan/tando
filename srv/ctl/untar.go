package ctl

import (
	"archive/tar"
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"tando/srv/internal/run"
)

// An artifact (docs/CONTROL-PLANE.md, "Artifacts") is a tar archive, gzip or zstd compressed,
// of exactly:
//
//	tando-artifact.json   the manifest (at most 64 KB)
//	release/...           the built output: what a laptop deploy would upload
//
// Unpacking trusts nothing in it: no absolute path, no "..", no entry under a symbolic link of
// the archive, no symbolic link that points outside release/, no hard link, device, FIFO or
// socket, no name twice; at most MaxEntries entries and MaxBytes bytes unpacked (a
// decompression bomb stops at the limit, whatever the archive claims); modes are reduced to
// 0644/0755 (no setuid, setgid or sticky bit), owners are not taken from the archive.

// ManifestName is the manifest's name in the archive.
const ManifestName = "tando-artifact.json"

// Limits of one unpack.
type Limits struct {
	MaxEntries int
	MaxBytes   int64 // the sum of the files' sizes
}

// Unpacked is what Unpack produced.
type Unpacked struct {
	Manifest []byte
	Entries  int
	Bytes    int64
}

// Compression is gzip or zstd, from the archive's first bytes.
func Compression(head []byte) string {
	switch {
	case bytes.HasPrefix(head, []byte{0x1f, 0x8b}):
		return "gzip"
	case bytes.HasPrefix(head, []byte{0x28, 0xb5, 0x2f, 0xfd}):
		return "zstd"
	}
	return ""
}

// zstd decompresses with the system's zstd (no zstd in Go's standard library), fed the verified
// file descriptor, its memory bounded; its output is capped like gzip's (Unpack's limits).
func zstd(ctx context.Context, rn run.Runner, f *os.File) (io.ReadCloser, func() error) {
	pr, pw := io.Pipe()
	done := make(chan error, 1)
	go func() {
		var stderr bytes.Buffer
		_, err := rn.Output(ctx, run.Cmd{Argv: []string{"/usr/bin/zstd", "--decompress", "--stdout", "--quiet", "--no-progress", "--memory=128MB"},
			Stdin: f, Stdout: pw, Stderr: &stderr, Timeout: 30 * time.Minute,
			Env: []string{"PATH=/usr/bin:/bin", "LC_ALL=C"}})
		if err != nil {
			err = fmt.Errorf("zstd (apt install zstd if it is missing): %s", clean(strings.TrimSpace(stderr.String()+" "+err.Error())))
		}
		pw.CloseWithError(err)
		done <- err
	}()
	return pr, func() error { return <-done }
}

// UnpackFile unpacks the artifact on f (at offset 0) into dst, which must not exist (its parent
// must be root's and closed to others: the caller's).
func UnpackFile(ctx context.Context, rn run.Runner, f *os.File, dst string, lim Limits) (Unpacked, error) {
	head := make([]byte, 4)
	if _, err := io.ReadFull(f, head); err != nil {
		return Unpacked{}, errors.New("the artifact is too short")
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return Unpacked{}, err
	}
	var r io.Reader
	var wait func() error
	switch Compression(head) {
	case "gzip":
		z, err := gzip.NewReader(bufio.NewReader(f))
		if err != nil {
			return Unpacked{}, fmt.Errorf("gzip: %v", err)
		}
		z.Multistream(false)
		r = z
	case "zstd":
		ctx, cancel := context.WithCancel(ctx)
		defer cancel() // (an unpack that stops early ends zstd)
		rc, w := zstd(ctx, rn, f)
		defer rc.Close()
		r, wait = rc, w
	default:
		return Unpacked{}, errors.New("the artifact is neither gzip nor zstd compressed (a .tar.gz or .tar.zst)")
	}
	u, err := Unpack(r, dst, lim)
	if err != nil {
		return u, err
	}
	if wait != nil {
		if err := wait(); err != nil {
			return u, err
		}
	}
	return u, nil
}

// Unpack reads a tar stream into dst (created here, 0700).
func Unpack(r io.Reader, dst string, lim Limits) (Unpacked, error) {
	var u Unpacked
	if err := os.Mkdir(dst, 0o700); err != nil {
		return u, err
	}
	tr := tar.NewReader(r)
	seen := map[string]byte{} // path -> 'd', 'f', 'l'
	for {
		h, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return u, fmt.Errorf("tar: %v", err)
		}
		if h.Typeflag == tar.TypeXGlobalHeader {
			continue
		}
		u.Entries++
		if u.Entries > lim.MaxEntries {
			return u, fmt.Errorf("more than %d entries", lim.MaxEntries)
		}
		name, err := entryName(h.Name)
		if err != nil {
			return u, err
		}
		if name == "" || name == "release" && h.Typeflag == tar.TypeDir { // ./ and release/ themselves
			if name == "release" {
				if err := mkdirIn(dst, name, seen); err != nil {
					return u, err
				}
			}
			continue
		}
		if seen[name] != 0 {
			return u, fmt.Errorf("%s: twice in the archive", clean(name))
		}
		if name == ManifestName {
			if h.Typeflag != tar.TypeReg || h.Size > 64<<10 {
				return u, errors.New("tando-artifact.json: a file of at most 64 KB")
			}
			if u.Manifest, err = io.ReadAll(io.LimitReader(tr, 64<<10)); err != nil {
				return u, fmt.Errorf("tar: %v", err)
			}
			seen[name] = 'f'
			continue
		}
		if !strings.HasPrefix(name, "release/") {
			return u, fmt.Errorf("%s: outside release/ (an artifact is tando-artifact.json and release/)", clean(name))
		}
		// no entry below a symbolic link of the archive (it would be written through it)
		for p := path.Dir(name); p != "."; p = path.Dir(p) {
			if seen[p] == 'l' || seen[p] == 'f' {
				return u, fmt.Errorf("%s: below %s, which is not a directory", clean(name), clean(p))
			}
		}
		if err := mkdirIn(dst, path.Dir(name), seen); err != nil {
			return u, err
		}
		full := filepath.Join(dst, filepath.FromSlash(name))
		switch h.Typeflag {
		case tar.TypeDir:
			if err := mkdirIn(dst, name, seen); err != nil {
				return u, err
			}
		case tar.TypeReg:
			if h.Size < 0 || u.Bytes+h.Size > lim.MaxBytes {
				return u, fmt.Errorf("over %d bytes unpacked", lim.MaxBytes)
			}
			mode := os.FileMode(0o644)
			if h.Mode&0o111 != 0 {
				mode = 0o755
			}
			out, err := os.OpenFile(full, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, mode)
			if err != nil {
				return u, fmt.Errorf("%s: %v", clean(name), err)
			}
			// (the header's size is what tar reads; a stream that is longer is the next header)
			n, err := io.Copy(out, io.LimitReader(tr, h.Size))
			cerr := out.Close()
			if err != nil || n != h.Size || cerr != nil {
				return u, fmt.Errorf("%s: short or unreadable (%v)", clean(name), err)
			}
			u.Bytes += n
			seen[name] = 'f'
		case tar.TypeSymlink:
			if err := linkInside(name, h.Linkname); err != nil {
				return u, err
			}
			if err := os.Symlink(h.Linkname, full); err != nil {
				return u, fmt.Errorf("%s: %v", clean(name), err)
			}
			seen[name] = 'l'
		case tar.TypeLink:
			return u, fmt.Errorf("%s: a hard link (not allowed in an artifact)", clean(name))
		default:
			return u, fmt.Errorf("%s: a device, FIFO or other special file (type %q)", clean(name), h.Typeflag)
		}
	}
	if u.Manifest == nil {
		return u, errors.New("no tando-artifact.json in the artifact")
	}
	if seen["release"] != 'd' {
		return u, errors.New("no release/ in the artifact")
	}
	return u, nil
}

// entryName is a tar name, checked and cleaned: relative, no "..", no control characters.
func entryName(n string) (string, error) {
	if n == "" || len(n) > 4096 || strings.ContainsFunc(n, func(r rune) bool { return r < 0x20 || r == 0x7f }) {
		return "", fmt.Errorf("bad name in the archive: %q", clean(n))
	}
	if strings.HasPrefix(n, "/") {
		return "", fmt.Errorf("%s: an absolute path", clean(n))
	}
	for _, p := range strings.Split(n, "/") {
		if p == ".." {
			return "", fmt.Errorf("%s: a path with ..", clean(n))
		}
	}
	c := path.Clean(n)
	if c == "." {
		return "", nil
	}
	if strings.Count(c, "/") > 64 {
		return "", fmt.Errorf("%s: deeper than 64 directories", clean(n))
	}
	return c, nil
}

// linkInside: a symbolic link of name with target t stays in release/ (relative, no way out).
func linkInside(name, t string) error {
	if t == "" || strings.HasPrefix(t, "/") || len(t) > 4096 || strings.ContainsFunc(t, func(r rune) bool { return r < 0x20 || r == 0x7f }) {
		return fmt.Errorf("%s: a symbolic link to an absolute or bad path", clean(name))
	}
	p := path.Join(path.Dir(name), t)
	if p != "release" && !strings.HasPrefix(p, "release/") {
		return fmt.Errorf("%s: a symbolic link that leaves release/", clean(name))
	}
	// (lexical, as written: every step of it inside; a link through another link is checked again
	// by the node when the release is imported, which refuses one that resolves outside)
	depth := strings.Count(path.Dir(name), "/") + 1
	for _, s := range strings.Split(t, "/") {
		switch s {
		case "..":
			depth--
		case "", ".":
		default:
			depth++
		}
		if depth < 1 {
			return fmt.Errorf("%s: a symbolic link that leaves release/", clean(name))
		}
	}
	return nil
}

// mkdirIn makes the directory rel (and its parents) inside dst, none of them a link or a file.
func mkdirIn(dst, rel string, seen map[string]byte) error {
	if rel == "." || rel == "" {
		return nil
	}
	parts := strings.Split(rel, "/")
	for i := range parts {
		p := strings.Join(parts[:i+1], "/")
		switch seen[p] {
		case 'd':
			continue
		case 'f', 'l':
			return fmt.Errorf("%s: not a directory in the archive", clean(p))
		}
		if p != "release" && !strings.HasPrefix(p, "release/") {
			return fmt.Errorf("%s: outside release/", clean(p))
		}
		if err := os.Mkdir(filepath.Join(dst, filepath.FromSlash(p)), 0o755); err != nil {
			return fmt.Errorf("%s: %v", clean(p), err)
		}
		seen[p] = 'd'
	}
	return nil
}
