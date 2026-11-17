package gate

import (
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"syscall"
)

// The upload tree (incoming/) as root sees it. Root never opens a file of the upload, never
// follows a link in it and never leaves its file system: the tree is read with directory
// descriptors, one entry at a time (fs_linux.go), and every check below works on what that walk
// recorded. Symlink targets are resolved here, inside the recorded tree, not by the kernel.

// node is one entry of the tree.
type node struct {
	rel    string // path below the top ("" is the top itself)
	mode   uint32 // st_mode
	uid    uint32
	nlink  uint64
	size   int64
	target string // a symlink's target
}

func (n *node) isDir() bool  { return n.mode&syscall.S_IFMT == syscall.S_IFDIR }
func (n *node) isReg() bool  { return n.mode&syscall.S_IFMT == syscall.S_IFREG }
func (n *node) isLink() bool { return n.mode&syscall.S_IFMT == syscall.S_IFLNK }

// tree is a walked directory: its absolute path and its entries by relative path.
type tree struct {
	top   string
	nodes map[string]*node
	order []string // walk order (for "the first offender")
}

func newTree(top string) *tree { return &tree{top: top, nodes: map[string]*node{}} }

func (t *tree) add(n *node) {
	t.nodes[n.rel] = n
	t.order = append(t.order, n.rel)
}

// maxHops: symlinks followed while resolving one path (the kernel's limit).
const maxHops = 40

// resolvesInside: the symlink at rel, resolved as `readlink -f` would, ends strictly inside the
// tree (not at its top). Stricter than readlink -f where it can only refuse more: a path that
// leaves the tree is outside even if a later ".." would come back, and an absolute target counts
// only when it names the tree's own path literally.
func (t *tree) resolvesInside(rel string) bool {
	cur := strings.Split(filepath.Dir(rel), "/")
	if filepath.Dir(rel) == "." {
		cur = nil
	}
	rest, ok := t.targetWords(t.nodes[rel])
	if !ok {
		return false
	}
	hops := 1
	for len(rest) > 0 {
		c := rest[0]
		rest = rest[1:]
		switch c {
		case "", ".":
			continue
		case "..":
			if len(cur) == 0 {
				return false // above the top
			}
			cur = cur[:len(cur)-1]
			continue
		}
		p := strings.Join(append(cur[:len(cur):len(cur)], c), "/")
		n, found := t.nodes[p]
		switch {
		case !found:
			// readlink -f accepts a missing last component only
			return len(rest) == 0
		case n.isLink():
			if hops++; hops > maxHops {
				return false
			}
			w, ok := t.targetWords(n)
			if !ok {
				return false
			}
			rest = append(w, rest...)
		case n.isDir():
			cur = append(cur, c)
		default:
			if len(rest) > 0 {
				return false // a file used as a directory
			}
			cur = append(cur, c)
		}
	}
	return len(cur) > 0
}

// targetWords splits a link's target; an absolute one must start with the top's own path.
func (t *tree) targetWords(n *node) ([]string, bool) {
	if n == nil || n.target == "" {
		return nil, false
	}
	tg := n.target
	if strings.HasPrefix(tg, "/") {
		rest, ok := strings.CutPrefix(tg, t.top+"/")
		if !ok {
			return nil, false
		}
		// cur is the top: the words are relative to it, but the caller starts from the link's
		// directory, so "../" up to the top is prepended
		up := strings.Count(filepath.Dir(n.rel), "/") + 1
		if filepath.Dir(n.rel) == "." {
			up = 0
		}
		w := make([]string, 0, up+8)
		for range up {
			w = append(w, "..")
		}
		return append(w, strings.Split(rest, "/")...), true
	}
	return strings.Split(tg, "/"), true
}

// escapingLinks are the symlinks whose target, resolved, is not inside the tree
// (drop_escaping_links).
func (t *tree) escapingLinks() []string {
	var r []string
	for _, rel := range t.order {
		if n := t.nodes[rel]; rel != "" && n.isLink() && !t.resolvesInside(rel) {
			r = append(r, rel)
		}
	}
	return r
}

// scanResult collects, during one walk, the first offender of each rule of scanUpload.
type scanResult struct {
	special, hardlink, owner, absLink, anyLink string
	n, bytes                                   int64 // entries below the top; bytes with the top (du -sxb)
	over                                       bool  // more entries than the limit: not all were kept
}

// see records one entry (the walk calls it for every entry, the top too).
func (s *scanResult) see(n *node, uid uint32) {
	s.bytes += n.size
	if n.rel == "" {
		return
	}
	s.n++
	first := func(p *string) {
		if *p == "" {
			*p = n.rel
		}
	}
	if !n.isReg() && !n.isDir() && !n.isLink() {
		first(&s.special)
	}
	if !n.isDir() && n.nlink > 1 {
		first(&s.hardlink)
	}
	if n.uid != uid || n.mode&0o7000 != 0 {
		first(&s.owner)
	}
	if n.isLink() {
		if strings.HasPrefix(n.target, "/") {
			first(&s.absLink)
		}
		first(&s.anyLink)
	}
}

// verdict is scan_upload's answer, checked in its order, with its messages: only plain files,
// directories and symlinks owned by the deploy user; no hardlinks (the copy would read their
// other name as root), no setuid/setgid/sticky, no symlink that resolves outside incoming/ (a
// container upload: no symlink at all); bounded size. "" when the upload may be copied.
func (s *scanResult) verdict(t *tree, container bool, lim Limits) string {
	switch {
	case s.special != "":
		return "special file in the upload: " + clean(s.special)
	case s.hardlink != "":
		return "hardlink in the upload: " + clean(s.hardlink)
	case s.owner != "":
		return "foreign owner or setuid/setgid bit in the upload: " + clean(s.owner)
	case s.absLink != "":
		return "absolute symlink in the upload: " + clean(s.absLink)
	case container && s.anyLink != "":
		return "symlink in a container upload: " + clean(s.anyLink)
	}
	if !s.over {
		if l := t.escapingLinks(); len(l) > 0 {
			return "symlink leaves the upload: " + clean(l[0])
		}
	}
	if s.n > lim.MaxFiles {
		return fmt.Sprintf("too many files in the upload (%d)", s.n)
	}
	if s.bytes > lim.MaxBytes {
		return fmt.Sprintf("the upload is larger than %d MB", lim.MaxBytes>>20)
	}
	return ""
}

// errStop ends a walk early (not an error for the caller).
var errStop = errors.New("stop")

// gone: the entry vanished or was swapped while we looked; it is skipped.
func gone(err error) bool {
	return errors.Is(err, syscall.ENOENT) || errors.Is(err, syscall.ENOTDIR) || errors.Is(err, syscall.ELOOP) ||
		errors.Is(err, syscall.ESTALE)
}
