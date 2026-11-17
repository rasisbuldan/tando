package gate

import (
	"os"
	"path/filepath"
	"regexp"

	"tando/srv/internal/bashread"
	"tando/srv/internal/decimal"
)

// kv reads one key of a key=value file (written by tando-agent or by us) the way the shell
// gate's kv() did: values only, never evaluated; the first line with that key wins; a value
// keeps a trailing "=" and a "\r"; a missing or unreadable file is empty; a last line without a
// newline is not read (bash's read loop drops it).
func kv(path, key string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return kvOf(data, key)
}

func kvOf(data []byte, key string) string { return bashread.First(data, key) }

// Limits of one upload into incoming/ (host.conf may lower or raise them): total bytes and
// entries, and the size of one file. Enforced while the upload runs (receive.go) and again on
// the frozen upload (tree.go).
type Limits struct {
	MaxBytes, MaxFiles, MaxFile int64
}

var (
	digits7 = regexp.MustCompile(`^[0-9]{1,7}$`)
	digits8 = regexp.MustCompile(`^[0-9]{1,8}$`)
)

func (g *Gate) limits() Limits {
	hc := filepath.Join(g.P.Root, "host.conf")
	data, _ := os.ReadFile(hc)
	mb, files, fmb := kvOf(data, "ci_max_mb"), kvOf(data, "ci_max_files"), kvOf(data, "ci_max_file_mb")
	if !digits7.MatchString(mb) {
		mb = "3072"
	}
	if !digits8.MatchString(files) {
		files = "200000"
	}
	if !digits7.MatchString(fmb) {
		fmb = "1024"
	}
	// (checked above: decimal reads "0300" as 300, bash's 10#)
	nmb, _ := decimal.Parse(mb, 7)
	nfiles, _ := decimal.Parse(files, 8)
	nfmb, _ := decimal.Parse(fmb, 7)
	return Limits{MaxBytes: nmb * 1048576, MaxFiles: nfiles, MaxFile: nfmb * 1048576}
}

// Lease is the app's upload lease (tando-agent's <app>/upload), read as root.
type Lease struct {
	Token, Who, ID string
	Remain         int64 // seconds left before tando-agent abandons it, less 5
}

func (g *Gate) lease(app string) Lease {
	data, _ := os.ReadFile(filepath.Join(g.appDir(app), "upload"))
	l := Lease{Token: kvOf(data, "token"), Who: kvOf(data, "who"), ID: kvOf(data, "id")}
	started := int64(0)
	if n, ok := decimal.Parse(kvOf(data, "started"), 18); ok {
		started = n
	}
	l.Remain = uploadTimeout - (g.now() - started) - 5
	return l
}

// frozen is the token of the upload being activated (CI/<app>/frozen, root 600).
func (g *Gate) frozen(app string) string {
	return kv(filepath.Join(g.home(app), "frozen"), "token")
}
