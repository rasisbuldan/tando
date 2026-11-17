package watch

import (
	"maps"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"

	"tando/srv/internal/cksum"
	"tando/srv/internal/kvfile"
)

// Cache keeps what a long-running caller (tandod) would otherwise read and parse again every
// minute: the key=value files (settings, host.conf, every app.conf and state, notifier files).
// Each use checks the file with one stat: a change of inode, size or modification time (as an
// atomic rename or an edit in place make) reads it again; a file that is gone is forgotten. The
// files stay the truth: nothing is written through the cache, and the durable state of the
// checks is read from disk every tick (commit.go needs that).
type Cache struct {
	mu   sync.Mutex
	kv   map[string]kvEntry
	apps string // the app list the entries were last pruned against
}

type kvEntry struct {
	ino, size uint64
	mtime     int64
	m         map[string]string
	sum       uint64 // (a checksum entry)
}

// NewCache is an empty cache.
func NewCache() *Cache { return &Cache{kv: map[string]kvEntry{}} }

// load returns the parsed file (a copy the caller may change), using the cache when it is
// still the same file. A missing file is empty, as kvfile.Load.
func (c *Cache) load(path string) (map[string]string, error) {
	if c == nil {
		return kvfile.Load(path)
	}
	fi, err := os.Stat(path)
	if err != nil {
		c.mu.Lock()
		delete(c.kv, path)
		c.mu.Unlock()
		return kvfile.Load(path)
	}
	mt, size := fi.ModTime().UnixNano(), uint64(fi.Size())
	var ino uint64
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		ino = uint64(st.Ino)
	}
	c.mu.Lock()
	e, ok := c.kv[path]
	c.mu.Unlock()
	if ok && e.ino == ino && e.size == size && e.mtime == mt {
		return maps.Clone(e.m), nil
	}
	m, err := kvfile.Load(path)
	if err != nil {
		return nil, err
	}
	c.mu.Lock()
	c.kv[path] = kvEntry{ino: ino, size: size, mtime: mt, m: maps.Clone(m)}
	c.mu.Unlock()
	return m, nil
}

// Forget drops the entries of files that no longer exist (an app that was removed): the cache
// never grows with what is gone.
func (c *Cache) Forget() {
	if c == nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	for p := range c.kv {
		if _, err := os.Lstat(strings.TrimPrefix(p, "\x00cksum\x00")); err != nil {
			delete(c.kv, p)
		}
	}
}

// cksum is the POSIX checksum of a file (show's version row: tando-watch's own 6 MB binary),
// computed again only when the file changed.
func (c *Cache) cksum(path string) (uint32, error) {
	if c == nil {
		return cksum.File(path)
	}
	fi, err := os.Stat(path)
	if err != nil {
		return 0, err
	}
	key := "\x00cksum\x00" + path
	mt, size := fi.ModTime().UnixNano(), uint64(fi.Size())
	var ino uint64
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		ino = uint64(st.Ino)
	}
	c.mu.Lock()
	e, ok := c.kv[key]
	c.mu.Unlock()
	if ok && e.ino == ino && e.size == size && e.mtime == mt {
		return uint32(e.sum), nil
	}
	sum, err := cksum.File(path)
	if err != nil {
		return 0, err
	}
	c.mu.Lock()
	c.kv[key] = kvEntry{ino: ino, size: size, mtime: mt, sum: uint64(sum)}
	c.mu.Unlock()
	return sum, nil
}

// keepApps drops the entries of apps that are no longer there (when the list of apps changed):
// the cache holds at most the files of the apps that exist.
func (c *Cache) keepApps(root string, names []string) {
	if c == nil {
		return
	}
	key := strings.Join(names, " ")
	c.mu.Lock()
	defer c.mu.Unlock()
	if key == c.apps {
		return
	}
	c.apps = key
	live := map[string]bool{}
	for _, a := range names {
		live[a] = true
	}
	prefix := filepath.Join(root, "apps") + "/"
	for p := range c.kv {
		rest, ok := strings.CutPrefix(strings.TrimPrefix(p, "\x00cksum\x00"), prefix)
		if a, _, _ := strings.Cut(rest, "/"); ok && !live[a] {
			delete(c.kv, p)
		}
	}
}

// Len is the number of cached files.
func (c *Cache) Len() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.kv)
}
