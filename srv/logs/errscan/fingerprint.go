package errscan

import (
	"fmt"
	"regexp"
	"strings"
)

// The group id is stored on servers (groups.tsv, samples/<id>) and shown to users, so every rule
// here is byte for byte the shell version's (awk in the C locale: bytes, not characters).

// ID is the group id of a fingerprint: djb2 over its bytes, modulo 2^32, as 8 hex digits.
func ID(fp string) string {
	var h uint32 = 5381
	for i := 0; i < len(fp); i++ {
		h = h*33 + uint32(fp[i])
	}
	return fmt.Sprintf("%08x", h)
}

// Norm folds what changes between two occurrences of the same error: 0x... becomes <hex>, a
// word of 8+ hex digits with a digit in it (ids, hashes, parts of uuids) <id>, a run of such ids
// joined by "-" one <id>, every other number <n>.
func Norm(s string) string {
	s = replaceHex(s)
	out := s
	// awk: split(s, P, /[^0-9A-Za-z]/), then each long hex word's first occurrence in the
	// string being rewritten becomes <id> (the first occurrence, wherever it is)
	start := 0
	for i := 0; i <= len(s); i++ {
		if i < len(s) && isAlnum(s[i]) {
			continue
		}
		if w := s[start:i]; len(w) >= 8 && isHexRun(w) {
			if c := strings.Index(out, w); c >= 0 {
				out = out[:c] + "<id>" + out[c+len(w):]
			}
		}
		start = i + 1
	}
	return replaceDigits(joinIDs(out))
}

func isAlnum(c byte) bool {
	return c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
}

func isHexRun(w string) bool {
	digit := false
	for i := 0; i < len(w); i++ {
		c := w[i]
		switch {
		case c >= '0' && c <= '9':
			digit = true
		case c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F':
		default:
			return false
		}
	}
	return digit
}

func isHex(c byte) bool { return c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F' }

// replaceHex: gsub(/0x[0-9a-fA-F]+/, "<hex>")
func replaceHex(s string) string {
	if !strings.Contains(s, "0x") {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '0' && i+2 < len(s) && s[i+1] == 'x' && isHex(s[i+2]) {
			j := i + 2
			for j < len(s) && isHex(s[j]) {
				j++
			}
			b.WriteString("<hex>")
			i = j - 1
			continue
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

// joinIDs: gsub(/<id>-<id>(-<id>)*/, "<id>")
func joinIDs(s string) string {
	if !strings.Contains(s, "<id>-<id>") {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); {
		if strings.HasPrefix(s[i:], "<id>-<id>") {
			j := i + 9
			for strings.HasPrefix(s[j:], "-<id>") {
				j += 5
			}
			b.WriteString("<id>")
			i = j
			continue
		}
		b.WriteByte(s[i])
		i++
	}
	return b.String()
}

// replaceDigits: gsub(/[0-9]+/, "<n>")
func replaceDigits(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] >= '0' && s[i] <= '9' {
			for i+1 < len(s) && s[i+1] >= '0' && s[i+1] <= '9' {
				i++
			}
			b.WriteString("<n>")
			continue
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

// cleanLine makes a line one field of a row: bytes below 0x20 and DEL become "?" (NUL is left as
// it is, as awk's [\001-\037\177]), and it is cut to 240 bytes, the last one "~".
func cleanLine(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 1 && c < 0x20 || c == 0x7f {
			b[i] = '?'
		}
	}
	if len(b) > 240 {
		b = append(b[:239], '~')
	}
	return string(b)
}

// frame rewriting: the release directory and line numbers go, so the same frame of the next
// release is the same frame (leftmost-longest, as awk's gsub)
var (
	reFileURL  = regexp.MustCompilePOSIX(`file://`)
	reAppDir   = regexp.MustCompilePOSIX(`/opt/tando/apps/[a-z0-9-]+/(releases/[0-9-]+/)?`)
	reRelDir   = regexp.MustCompilePOSIX(`/releases/[0-9-]+/`)
	reLineCols = regexp.MustCompilePOSIX(`:[0-9]+(:[0-9]+)?`)
)

// frame: an app frame as it goes into a fingerprint.
func frame(fr string) string {
	fr = reFileURL.ReplaceAllLiteralString(fr, "")
	fr = reAppDir.ReplaceAllLiteralString(fr, "")
	fr = reRelDir.ReplaceAllLiteralString(fr, "/")
	fr = reLineCols.ReplaceAllLiteralString(fr, "")
	return Norm(fr)
}
