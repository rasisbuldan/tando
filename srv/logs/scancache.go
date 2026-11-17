package logs

import (
	"context"
	"fmt"
	"strconv"

	"os"
	"path/filepath"
	"strings"
	"sync"
	"tando/srv/internal/fsinfo"

	"tando/srv/logs/lines"
	"tando/srv/logs/reqlog"
)

// ScanCache is what the scans of a long-running caller (tandod calls WatchScan every minute)
// keep between calls: for each app the signatures (inode, size, mtime) of the files that show
// whether anything was written since its last full scan, the request index in memory with its
// path dictionaries, and buffers to reuse. An app whose journal and request log are as they were
// costs a few stat calls and no allocation: its row is the one a full scan would print (all
// zeros), without a lock, a file read or journalctl. A one-shot run uses a fresh cache, so both
// run the same code. Files on disk stay the truth: a cached index is used only while its state
// file is the one this cache wrote or read.
type ScanCache struct {
	mu      sync.Mutex
	appsSig fsig
	appsDir []byte   // Root/apps, NUL-terminated
	apps    []string // the entries of appsDir, while appsSig is unchanged
	live    []string // reused for the live ones
	per     map[string]*appScan
	lr      *lines.Reader
	parser  *reqlog.Parser
	st      statBuf
}

// NewScanCache returns an empty cache.
func NewScanCache() *ScanCache { return &ScanCache{per: map[string]*appScan{}} }

// fsig is a file's signature; ok is false when it does not exist.
type fsig struct {
	ok          bool
	ino         uint64
	size, mtime int64 // mtime in nanoseconds
}

// appScan is one app's part of the cache.
type appScan struct {
	p struct { // paths, NUL-terminated for the stat calls
		state, conf, nsConf, nsDir, journal, logDir, access []byte
	}
	state    fsig
	live     bool
	idle     bool    // the signatures below are those taken before the last full scan
	sigs     [6]fsig // nsConf, nsDir, journal, logDir, access, app.conf
	idx      *reqIndex
	idxSig   fsig // the index's state file as this cache last wrote or read it
	idxBytes string
	files    map[string]*fileMeta
	pos      map[string]int64    // the scan's position: first-line hash of a log file -> bytes counted (req.idx)
	posRec   map[string][2]int64 // the same position as (bytes, its record number in the segment)
	posSig   fsig
	posBytes string
	reqIno   uint64
	tooMany  bool
	reqOff   int64
	dirsOK   bool
}

// fileMeta: what was learned of a request log file, while its inode and size allow.
type fileMeta struct {
	ino  uint64
	size int64
	gz   bool
	fp   string
}

func cpath(p string) []byte { return append([]byte(p), 0) }

func (c *ScanCache) app(l *Logs, name string) *appScan {
	if as := c.per[name]; as != nil {
		return as
	}
	as := &appScan{files: map[string]*fileMeta{}}
	dir := filepath.Join(l.Env.Root, "apps", name)
	as.p.state = cpath(filepath.Join(dir, "state"))
	as.p.conf = cpath(filepath.Join(dir, "app.conf"))
	as.p.nsConf = cpath(filepath.Join(l.P.Systemd, "journald@tando-"+name+".conf"))
	if id := l.machineID(); id != "" {
		nd := filepath.Join(l.P.Journal, id+".tando-"+name)
		as.p.nsDir = cpath(nd)
		as.p.journal = cpath(filepath.Join(nd, "system.journal"))
	}
	as.p.logDir = cpath(filepath.Join(l.P.LogDir, name))
	as.p.access = cpath(filepath.Join(l.P.LogDir, name, "access.log"))
	c.per[name] = as
	return as
}

// signatures takes the signatures that decide whether the app can be skipped (no allocation):
// the active journal file (journald writes, rotates to a new inode, or makes it), the request log
// (Caddy appends, rolls to a new inode); the namespace's config only when there is no journal
// file (an app that does not log into a namespace: a static site). [0] config, [2] journal,
// [4] access.log; the others are not taken (three stat calls an app, four without a journal).
func (c *ScanCache) signatures(as *appScan) [6]fsig {
	var s [6]fsig
	if as.p.journal != nil {
		s[2] = c.st.stat(as.p.journal)
	}
	if !s[2].ok {
		s[0] = c.st.stat(as.p.nsConf)
	}
	s[4] = c.st.stat(as.p.access)
	return s
}

// liveApps: the apps whose state names a current release, re-read only where the apps
// directory or a state file changed.
func (c *ScanCache) liveApps(l *Logs) []string {
	dir := filepath.Join(l.Env.Root, "apps")
	if c.appsDir == nil {
		c.appsDir = cpath(dir)
	}
	sig := c.st.stat(c.appsDir)
	if !sig.ok || sig != c.appsSig || c.apps == nil {
		ents, _ := os.ReadDir(dir)
		c.apps = c.apps[:0]
		here := map[string]bool{}
		for _, e := range ents {
			c.apps = append(c.apps, e.Name())
			here[e.Name()] = true
		}
		c.appsSig = sig
		for n := range c.per { // apps gone: what was kept of them goes too
			if !here[n] {
				delete(c.per, n)
			}
		}
	}
	live := c.live[:0]
	for _, n := range c.apps {
		as := c.app(l, n)
		if s := c.st.stat(as.p.state); s != as.state || !s.ok {
			as.state, as.live = s, false
			if s.ok {
				if b, err := os.ReadFile(string(as.p.state[:len(as.p.state)-1])); err == nil {
					for line := range strings.SplitSeq(string(b), "\n") {
						if len(line) > len("current=") && strings.HasPrefix(line, "current=") {
							as.live = true
							break
						}
					}
				}
			}
		}
		if as.live {
			live = append(live, n)
		}
	}
	c.live = live
	return live
}

// Bounds on what a cache keeps of path dictionaries between calls: a dictionary is kept only when
// small, and all of them together stay under cacheDicts. Anything else is read again (streaming)
// when a new line needs it; a client requesting unique URLs cannot grow a long-running caller.
const (
	keepDict   = 32 << 10
	cacheDicts = 512 << 10
)

// trimDicts drops, after a roll, the dictionaries of x that are not worth keeping: those of
// segments that will not grow (complete, or read from the log), large ones, and any once the
// cache's total would pass cacheDicts.
func (c *ScanCache) trimDicts(x *reqIndex) {
	total := c.dictBytes(x)
	for _, s := range x.segs {
		if s.dict == nil {
			continue
		}
		m := s.dict.Mem()
		if s.Flags&(segComplete|segRaw) != 0 || m > keepDict || total+m > cacheDicts {
			s.dict = nil
			continue
		}
		total += m
	}
}

// dictBytes: the dictionaries the cache holds in memory, except those of skip.
func (c *ScanCache) dictBytes(skip *reqIndex) int {
	n := 0
	for _, as := range c.per {
		if as.idx == nil || as.idx == skip {
			continue
		}
		for _, s := range as.idx.segs {
			if s.dict != nil {
				n += s.dict.Mem()
			}
		}
	}
	return n
}

// Held is about what the cache holds between calls, in bytes (for tests and measurements).
func (c *ScanCache) Held() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	n := c.dictBytes(nil)
	for name, as := range c.per {
		n += 512 + len(name) + len(as.idxBytes) + len(as.posBytes) + 64*len(as.files)
		if as.idx != nil {
			n += 128 * len(as.idx.segs)
			for _, s := range as.idx.segs {
				n += cap(s.recs)
			}
		}
	}
	return n
}

// tooManyLogFiles: a request log directory with more files than tando would ever make. It is
// worked on bounded (logNames) and said once: a marker for log-doctor and a line in the audit
// trail when it first appears; the marker goes when the directory is back to normal.
func (l *Logs) tooManyLogFiles(a *app, over int) {
	p := filepath.Join(a.scanDir(), "toomany")
	if over == 0 {
		if a.as != nil && a.as.tooMany {
			os.Remove(p)
			a.as.tooMany = false
		} else if a.as == nil {
			os.Remove(p)
		}
		return
	}
	if a.as != nil && a.as.tooMany {
		return
	}
	if !fsinfo.ExistsNoFollow(p) {
		l.AuditWrite(context.Background(), []string{"log-files", a.name, "failed",
			fmt.Sprintf("over %d files in the request log directory: %d left out", maxLogFiles, over)})
	}
	writeInPlace(p, []byte(strconv.Itoa(over)+"\n"), 0o644)
	if a.as != nil {
		a.as.tooMany = true
	}
}

// forget drops what is known of an app (removed: its files are gone).
func (c *ScanCache) forget(name string) {
	c.mu.Lock()
	delete(c.per, name)
	c.mu.Unlock()
}
