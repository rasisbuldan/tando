// Package bashread splits text the way the shell versions of the programs read it with bash's
// read builtin, which is part of their contract: complete lines only (`while read` drops a last
// line without a newline), tab-separated fields (`IFS=$'\t' read -r a b c`), and key=value lines
// (split at the first "="). Where a program read differently on purpose (grep and awk also take an
// unterminated last line; kvfile's own files) the difference is an option, named at the call.
//
// A leaf: it imports only bytes and strings (tando-gate links it). Pure: no files.
package bashread

import (
	"bytes"
	"strings"
)

// Lines splits b into the lines `while IFS= read -r l` sees: a last line without a newline is
// dropped. No newline at all: nil.
func Lines(b []byte) []string {
	var res []string
	for len(b) > 0 {
		i := bytes.IndexByte(b, '\n')
		if i < 0 {
			break
		}
		res = append(res, string(b[:i]))
		b = b[i+1:]
	}
	return res
}

// LinesAll splits b into lines as grep and awk read them: a last line without a newline counts.
func LinesAll(b []byte) []string {
	var res []string
	for len(b) > 0 {
		i := bytes.IndexByte(b, '\n')
		if i < 0 {
			res = append(res, string(b))
			break
		}
		res = append(res, string(b[:i]))
		b = b[i+1:]
	}
	return res
}

// Fields splits a line like `IFS=$'\t' read -r v1 ... vn`: tab is IFS whitespace, so leading
// and trailing tabs are dropped and a run of tabs is one separator (an empty field vanishes); the
// last of the n variables gets the rest of the line. Always n values ("" for the missing ones).
func Fields(line string, n int) []string {
	res := make([]string, n)
	s := strings.Trim(line, "\t")
	for i := 0; i < n && s != ""; i++ {
		if i == n-1 {
			res[i] = s
			break
		}
		f, rest, _ := strings.Cut(s, "\t")
		res[i] = f
		s = strings.TrimLeft(rest, "\t")
	}
	return res
}

// KV reads key=value lines one at a time: each line is split at its first "=" (a value keeps a
// trailing "=" and a "\r", as in bash); a line without "=" or with an empty key is skipped. By
// default it reads as the agent's `load` and the shell gate's `kv` did (`while IFS= read -r`):
// complete lines only, bytes as they are. The zero value reads nothing; set Data. Keys and
// values are substrings of Data (no copy per line).
//
//	for k, v, ok := r.Next(); ok; k, v, ok = r.Next() { ... }
type KV struct {
	Data string // what is left to read

	Partial      bool // a last line without a newline counts too (kvfile's own files)
	DropNUL      bool // NUL bytes are dropped from a line first (bash's read does: the agent's load)
	SkipComments bool // a key starting with "#" is skipped (a comment that happens to contain "=")
}

// Next is the next key and value, ok false at the end.
func (r *KV) Next() (key, value string, ok bool) {
	for len(r.Data) > 0 {
		var line string
		i := strings.IndexByte(r.Data, '\n')
		switch {
		case i >= 0:
			line, r.Data = r.Data[:i], r.Data[i+1:]
		case r.Partial:
			line, r.Data = r.Data, ""
		default:
			r.Data = "" // unterminated last line: read drops it
			return "", "", false
		}
		if r.DropNUL && strings.IndexByte(line, 0) >= 0 {
			line = strings.ReplaceAll(line, "\x00", "")
		}
		eq := strings.IndexByte(line, '=')
		if eq <= 0 || (r.SkipComments && line[0] == '#') {
			continue
		}
		return line[:eq], line[eq+1:], true
	}
	return "", "", false
}

// First is the value of the first line with key ("" when none): the shell gate's kv, which
// stopped at the first match.
func First(data []byte, key string) string {
	r := KV{Data: string(data)}
	for k, v, ok := r.Next(); ok; k, v, ok = r.Next() {
		if k == key {
			return v
		}
	}
	return ""
}
