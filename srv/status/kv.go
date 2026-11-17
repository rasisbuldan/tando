package status

import (
	"errors"
	"io"
	"io/fs"
	"os"
	"syscall"

	"tando/srv/internal/bashread"
)

// maxKV bounds what is read of one key=value file (app.conf, state, activation, host.conf). The
// agent writes them; a damaged or giant one must not take the memory of every status call. What
// lies beyond is not read (its cut-off last line counts as unterminated, so it is dropped).
const maxKV = 4 << 20

// kv is a key=value file as the agent's `load` reads it into a bash associative array:
//
//   - only complete lines: `while IFS= read -r line` drops a last line without a newline;
//   - each line is split at its first "=", the key must be non-empty, the value keeps a
//     trailing "=" and a "\r";
//   - bash's read drops NUL bytes;
//   - a later duplicate replaces the value but keeps the key's place (order is the order of
//     first assignment, which decides bash's iteration order, see bashOrder);
//   - a missing or unreadable file is empty (`[[ -r $1 ]] || return 0`).
type kv struct {
	m     map[string]string
	order []string
}

// get is ${X[k]:-}: "" when missing.
func (k kv) get(key string) string { return k.m[key] }

// or is ${X[k]:-def}: def when the key is missing or empty.
func (k kv) or(key, def string) string {
	if v := k.m[key]; v != "" {
		return v
	}
	return def
}

func (k kv) has(key string) bool { _, ok := k.m[key]; return ok }

// parseKV parses b as `load` does.
func parseKV(b []byte) kv {
	k := kv{m: map[string]string{}}
	r := bashread.KV{Data: string(b), DropNUL: true}
	for key, val, ok := r.Next(); ok; key, val, ok = r.Next() {
		if _, ok := k.m[key]; !ok {
			k.order = append(k.order, key)
		}
		k.m[key] = val
	}
	return k
}

// loadKV reads path (following a symlink, as bash does: these files are in root-owned
// directories) with the bound maxKV. Every error reads as an empty file, as in the shell.
func loadKV(path string) kv {
	b, _ := readBounded(path, maxKV, false)
	return parseKV(b)
}

// readBounded reads at most max bytes of path. noFollow refuses a symlink in the last element
// (O_NOFOLLOW), for files in directories another user can write. Only regular files are read:
// a FIFO planted there must not hang a root process.
func readBounded(path string, max int64, noFollow bool) ([]byte, error) {
	flags := os.O_RDONLY | syscall.O_NONBLOCK
	if noFollow {
		flags |= syscall.O_NOFOLLOW
	}
	f, err := os.OpenFile(path, flags, 0)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !fi.Mode().IsRegular() {
		return nil, &fs.PathError{Op: "read", Path: path, Err: errors.New("not a regular file")}
	}
	n := fi.Size()
	if n > max {
		n = max
	}
	b := make([]byte, 0, n+1)
	_, err = io.Copy(&limitedBuf{b: &b, max: int(max)}, f)
	return b, err
}

type limitedBuf struct {
	b   *[]byte
	max int
}

func (l *limitedBuf) Write(p []byte) (int, error) {
	if room := l.max - len(*l.b); room > 0 {
		*l.b = append(*l.b, p[:min(room, len(p))]...)
	}
	return len(p), nil
}

// bashOrder is the order in which bash 5 lists the keys of an associative array ("${!P[@]}"):
// a hash table of 1024 buckets (ASSOC_HASH_BUCKETS), the bucket of a key is its 32-bit FNV-1
// hash (hashlib.c hash_string) masked to 10 bits, buckets are walked from 0 up, and in a
// bucket the key assigned last comes first (hash_insert puts a new item at the head). keys
// are in the order of first assignment. deploy-status prints the activation file in this order;
// it was checked against bash 5.2 and 5.3 (test/e2e-status.sh compares the whole output).
func bashOrder(keys []string) []string {
	const buckets = 1024
	type item struct {
		bucket uint32
		seq    int
	}
	it := make([]item, len(keys))
	for i, k := range keys {
		h := uint32(2166136261)
		for j := 0; j < len(k); j++ {
			h *= 16777619
			h ^= uint32(k[j])
		}
		it[i] = item{h & (buckets - 1), i}
	}
	idx := make([]int, len(keys))
	for i := range idx {
		idx[i] = i
	}
	// stable order: bucket ascending, then the later assignment first
	sortInts(idx, func(a, b int) bool {
		if it[a].bucket != it[b].bucket {
			return it[a].bucket < it[b].bucket
		}
		return it[a].seq > it[b].seq
	})
	res := make([]string, len(keys))
	for i, j := range idx {
		res[i] = keys[j]
	}
	return res
}

// sortInts is an insertion sort: the lists are short (an activation file has about 15 keys).
func sortInts(a []int, less func(x, y int) bool) {
	for i := 1; i < len(a); i++ {
		for j := i; j > 0 && less(a[j], a[j-1]); j-- {
			a[j], a[j-1] = a[j-1], a[j]
		}
	}
}

// words splits s like an unquoted bash expansion with the default IFS: on runs of space, tab
// and newline only (not \r, \v or Unicode spaces, which strings.Fields would also split on).
func words(s string) []string {
	var res []string
	start := -1
	for i := 0; i <= len(s); i++ {
		if i == len(s) || s[i] == ' ' || s[i] == '\t' || s[i] == '\n' {
			if start >= 0 {
				res = append(res, s[start:i])
				start = -1
			}
			continue
		}
		if start < 0 {
			start = i
		}
	}
	return res
}
