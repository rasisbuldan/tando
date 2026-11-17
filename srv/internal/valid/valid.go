// Package valid checks untrusted words (arguments, values read from files) before they are used.
// Names are checked against the same patterns as the shell programs, which are the contract.
//
// Layer: internal. It imports internal/decimal; never a domain package or daemon.
package valid

import (
	"regexp"

	"tando/srv/internal/decimal"
)

var (
	appRe = regexp.MustCompile(`^[a-z][a-z0-9-]{1,25}$`)
	idRe  = regexp.MustCompile(`^[0-9]{8}-[0-9]{6}(-[0-9]{1,3})?$`)
)

// App: an app name (`valid_app` of the shell programs). It is also a path element and part of
// unit, user and slice names, so nothing else may pass.
func App(s string) bool { return appRe.MatchString(s) }

// ID: a release id, 20261114-170102 or 20261114-170102-2.
func ID(s string) bool { return idRe.MatchString(s) }

// Uint parses a plain decimal number within [lo, hi]: digits only, no sign, no spaces. Leading
// zeros are decimal ("08" is 8; bash arithmetic read it as octal and failed). At most 18 digits,
// so the value always fits in an int64.
func Uint(s string, lo, hi int64) (int64, bool) {
	n, ok := decimal.Parse(s, 18)
	if !ok {
		return 0, false
	}
	return n, n >= lo && n <= hi
}
