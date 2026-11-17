// Package decimal reads and writes plain decimal numbers: digits only, no sign, no spaces, no
// base prefix, leading zeros decimal ("08" is 8: bash arithmetic read it as octal and failed). It
// is the one digit parser of srv/: valid.Uint, the gate's uids and limits, tando-watch's numbers,
// tando-logs' counts and the socket protocol's counts use it.
//
// A leaf: it imports nothing but strconv (tando-gate links it).
package decimal

import "strconv"

// Parse reads s when it is 1 to maxDigits ASCII digits and nothing else; maxDigits must be at
// most 18, so the value always fits in an int64.
func Parse(s string, maxDigits int) (int64, bool) {
	if s == "" || len(s) > maxDigits {
		return 0, false
	}
	var n int64
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + int64(c-'0')
	}
	return n, true
}

// IsDigits: one or more ASCII digits (bash's [[ $x =~ ^[0-9]+$ ]]), of any length.
func IsDigits(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// Itoa is n in decimal.
func Itoa(n int64) string { return strconv.FormatInt(n, 10) }
