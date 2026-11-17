package gate

import (
	"strings"
	"syscall"
	"testing"
)

const top = "/opt/tando/apps/alpha/incoming"

// mk builds a tree: "d:" directories, "l:" symlinks ("l:name>target"), others files.
func mk(entries ...string) *tree {
	t := newTree(top)
	t.add(&node{rel: "", mode: syscall.S_IFDIR | 0o700, uid: 990, nlink: 2, size: 4096})
	for _, e := range entries {
		switch {
		case strings.HasPrefix(e, "d:"):
			t.add(&node{rel: e[2:], mode: syscall.S_IFDIR | 0o755, uid: 990, nlink: 2, size: 4096})
		case strings.HasPrefix(e, "l:"):
			name, target, _ := strings.Cut(e[2:], ">")
			t.add(&node{rel: name, mode: syscall.S_IFLNK | 0o777, uid: 990, nlink: 1, size: int64(len(target)), target: target})
		default:
			t.add(&node{rel: e, mode: syscall.S_IFREG | 0o644, uid: 990, nlink: 1, size: 10})
		}
	}
	return t
}

func TestResolvesInside(t *testing.T) {
	tr := mk("d:node_modules", "d:node_modules/pkg", "d:node_modules/pkg/bin", "node_modules/pkg/bin/x.js",
		"d:node_modules/.bin", "l:node_modules/.bin/x>../pkg/bin/x.js", "l:node_modules/.bin/y>../pkg/bin/missing",
		"server.js", "l:a>server.js", "l:b>./a", "l:c>d/../server.js", "d:d", "l:loop1>loop2", "l:loop2>loop1",
		"l:up>..", "l:self>.", "l:out>../../bravo/env", "l:out2>node_modules/../../incoming/server.js",
		"l:abs>/etc/shadow", "l:absin>"+top+"/server.js", "l:abstop>"+top, "l:absdot>"+top+"/../incoming/server.js",
		"l:filedir>server.js/x", "l:missdeep>nope/x", "l:dirlink>node_modules", "l:via>dirlink/pkg/bin/x.js",
		"l:viaout>up/bravo", "d:d/e", "l:d/e/up2>../../server.js", "l:d/e/up3>../../../x", "l:trail>d/",
		"l:empty>", "l:dots>d/./e/..")
	inside := map[string]bool{
		"node_modules/.bin/x": true, "node_modules/.bin/y": true, "a": true, "b": true, "c": true,
		"loop1": false, "loop2": false, "up": false, "self": false, "out": false, "out2": false,
		"abs": false, "absin": true, "abstop": false, "absdot": false, "filedir": false, "missdeep": false,
		"dirlink": true, "via": true, "viaout": false, "d/e/up2": true, "d/e/up3": false, "trail": true,
		"empty": false, "dots": true,
	}
	for rel, want := range inside {
		if got := tr.resolvesInside(rel); got != want {
			t.Errorf("%s -> %s: inside %v, want %v", rel, tr.nodes[rel].target, got, want)
		}
	}
	esc := strings.Join(tr.escapingLinks(), " ")
	if esc != "loop1 loop2 up self out out2 abs abstop absdot filedir missdeep viaout d/e/up3 empty" {
		t.Errorf("escaping links: %s", esc)
	}
}

func scanOf(tr *tree, container bool, lim Limits) string {
	var s scanResult
	for _, rel := range tr.order {
		s.see(tr.nodes[rel], 990)
	}
	return s.verdict(tr, container, lim)
}

func TestScanVerdict(t *testing.T) {
	lim := Limits{MaxBytes: 1 << 20, MaxFiles: 5, MaxFile: 1 << 20}
	if v := scanOf(mk("d:a", "a/b", "l:c>a/b"), false, lim); v != "" {
		t.Fatalf("a clean upload: %q", v)
	}
	tests := []struct {
		name string
		edit func(*tree)
		cont bool
		want string
	}{
		{"fifo", func(tr *tree) { tr.add(&node{rel: "f", mode: syscall.S_IFIFO | 0o644, uid: 990}) }, false, "special file in the upload: f"},
		{"device", func(tr *tree) { tr.add(&node{rel: "null", mode: syscall.S_IFCHR | 0o666, uid: 0}) }, false, "special file in the upload: null"},
		{"hardlink", func(tr *tree) { tr.nodes["a/b"].nlink = 2 }, false, "hardlink in the upload: a/b"},
		{"root's file", func(tr *tree) { tr.nodes["a/b"].uid = 0 }, false, "foreign owner or setuid/setgid bit in the upload: a/b"},
		{"setuid", func(tr *tree) { tr.nodes["a/b"].mode |= 0o4000 }, false, "foreign owner or setuid/setgid bit in the upload: a/b"},
		{"setgid dir", func(tr *tree) { tr.nodes["a"].mode |= 0o2000 }, false, "foreign owner or setuid/setgid bit in the upload: a"},
		{"sticky", func(tr *tree) { tr.nodes["a"].mode |= 0o1000 }, false, "foreign owner or setuid/setgid bit in the upload: a"},
		{"absolute link", func(tr *tree) { tr.add(&node{rel: "s", mode: syscall.S_IFLNK, uid: 990, target: "/etc/shadow"}) }, false, "absolute symlink in the upload: s"},
		{"absolute link inside", func(tr *tree) { tr.add(&node{rel: "s", mode: syscall.S_IFLNK, uid: 990, target: top + "/a"}) }, false, "absolute symlink in the upload: s"},
		{"container link", nil, true, "symlink in a container upload: c"},
		{"relative link out", func(tr *tree) {
			tr.add(&node{rel: "image-ref", mode: syscall.S_IFLNK, uid: 990, target: "../../bravo/shared/data/db.json"})
		}, false, "symlink leaves the upload: image-ref"},
		{"control characters in a name", func(tr *tree) {
			tr.add(&node{rel: ".env\xc2\x9b2J\n1\tx", mode: syscall.S_IFIFO, uid: 990})
		}, false, "special file in the upload: .env?2J?1?x"},
		{"too many", func(tr *tree) {
			for _, n := range []string{"x1", "x2", "x3"} {
				tr.add(&node{rel: n, mode: syscall.S_IFREG, uid: 990, nlink: 1})
			}
		}, false, "too many files in the upload (6)"},
		{"too big", func(tr *tree) { tr.nodes["a/b"].size = 2 << 20 }, false, "the upload is larger than 1 MB"},
		{"the order of the rules", func(tr *tree) {
			tr.nodes["a/b"].size = 2 << 20
			tr.nodes["a/b"].uid = 1
			tr.add(&node{rel: "f", mode: syscall.S_IFIFO, uid: 990})
		}, false, "special file in the upload: f"},
	}
	for _, tt := range tests {
		tr := mk("d:a", "a/b", "l:c>a/b")
		if tt.edit != nil {
			tt.edit(tr)
		}
		if got := scanOf(tr, tt.cont, lim); got != tt.want {
			t.Errorf("%s: %q, want %q", tt.name, got, tt.want)
		}
	}
}
