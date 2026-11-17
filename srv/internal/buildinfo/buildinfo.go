// Package buildinfo carries the tando version a binary was built from. scripts/build-server.sh
// sets it from VERSION with -ldflags "-X tando/srv/internal/buildinfo.Version=X.Y.Z"; a plain
// `go build` leaves "unknown", the word tando-agent prints when /opt/tando/VERSION is missing.
//
// Layer: internal: no imports at all.
package buildinfo

// Version is X.Y.Z, the same string `tando version` and /opt/tando/VERSION hold.
var Version = "unknown"
