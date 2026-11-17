package gate

import (
	"bufio"
	"io"
	"strings"
)

// Params are root mode's parameters: key=value lines on stdin, written by key mode. Only
// whitelisted keys, each checked; nothing else is read.
type Params struct{ Token, Build, Upload string }

const (
	maxParamLine = 200 // bytes per read (a longer line is read in pieces, as `read -n 200` did)
	maxParams    = 8
)

// ReadParams reads the parameters (read_params). A last piece without a newline is dropped, as
// bash's read drops it; an empty key (an empty line) is skipped.
func ReadParams(r io.Reader) (Params, error) {
	var p Params
	br := bufio.NewReaderSize(r, 4096)
	for n := 1; ; n++ {
		l, ok := readPiece(br, maxParamLine)
		if !ok {
			return p, nil
		}
		if n > maxParams {
			return p, die("too many parameters")
		}
		k, v, has := strings.Cut(l, "=")
		if !has {
			v = ""
		}
		switch k {
		case "token":
			if !validToken(v) {
				return p, die("bad token")
			}
			p.Token = v
		case "build":
			if !validSecs(v) {
				return p, die("bad timing")
			}
			p.Build = v
		case "upload":
			if !validSecs(v) {
				return p, die("bad timing")
			}
			p.Upload = v
		case "":
		default:
			return p, die("unknown parameter")
		}
	}
}

// readPiece is bash's `IFS= read -r -n max l`: up to a newline (not kept) or max bytes; false at
// the end of the input, with what was read before it (bash's read fails but sets l). NUL bytes are
// dropped, as bash drops them (but count towards max, so a stream of them ends the piece).
func readPiece(br *bufio.Reader, max int) (string, bool) {
	var b strings.Builder
	for i := 0; i < max; i++ {
		c, err := br.ReadByte()
		if err != nil {
			return b.String(), false
		}
		if c == '\n' {
			return b.String(), true
		}
		if c != 0 {
			b.WriteByte(c)
		}
	}
	return b.String(), true
}
