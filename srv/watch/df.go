package watch

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"tando/srv/internal/fsinfo"
)

// fsUse is what `df --output=target,pcent,ipcent <path>` says, read with statfs(2) instead of a
// fork: the mount point, % of blocks and % of inodes used ("" when the file system does not say,
// df's "-").
type fsUse struct {
	target    string
	pct, ipct string
}

// df measures the file system of path like GNU df: used = blocks - free, available to non-root =
// bavail, percentage = used / (used + available) rounded up; inodes the same with files - ffree
// and ffree. A path that cannot be measured is not reported.
func (w Watch) df(path string, mounts []string) (fsUse, bool) {
	fs, err := fsinfo.Statfs(path)
	if err != nil {
		return fsUse{}, false
	}
	u := fsUse{target: mountOf(path, mounts)}
	u.pct = pctUp(fs.Blocks-fs.Free, fs.Avail)
	if fs.Files > 0 {
		u.ipct = pctUp(fs.Files-fs.FilesFree, fs.FilesFree)
	}
	return u, true
}

func pctUp(used, avail uint64) string {
	total := used + avail
	if total == 0 {
		return ""
	}
	p := used * 100 / total
	if used*100%total != 0 {
		p++
	}
	return strconv.FormatUint(p, 10)
}

// mounts are the mount points of /proc/self/mountinfo, in its order (a later one over-mounts an
// earlier one at the same place).
func (w Watch) mounts() []string {
	b, err := os.ReadFile(filepath.Join(w.Env.Proc, "self", "mountinfo"))
	if err != nil {
		return nil
	}
	var res []string
	for l := range strings.SplitSeq(string(b), "\n") {
		f := strings.Fields(l)
		if len(f) > 4 {
			res = append(res, unescapeMount(f[4]))
		}
	}
	return res
}

// unescapeMount undoes the kernel's octal escapes (\040 for a space).
func unescapeMount(s string) string {
	if !strings.Contains(s, `\`) {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+4 <= len(s) {
			if n, err := strconv.ParseUint(s[i+1:i+4], 8, 8); err == nil {
				b.WriteByte(byte(n))
				i += 3
				continue
			}
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

// mountOf is the mount point path is on: the longest mount point that contains it (symlinks
// resolved), "/" when none does.
func mountOf(path string, mounts []string) string {
	if p, err := filepath.EvalSymlinks(path); err == nil {
		path = p
	}
	best := "/"
	for _, m := range mounts {
		if (m == path || strings.HasPrefix(path, strings.TrimSuffix(m, "/")+"/")) && len(m) >= len(best) {
			best = m
		}
	}
	return best
}
