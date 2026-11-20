// Package buildinfo carries the tando version a binary was built from. scripts/build-server.sh
// sets it from VERSION with -ldflags "-X tando/srv/internal/buildinfo.Version=X.Y.Z"; a plain
// `go build` leaves "unknown", the word tando-agent prints when /opt/tando/VERSION is missing.
//
// Layer: internal: no imports at all.
package buildinfo

// Version is X.Y.Z, the same string `tando version` and /opt/tando/VERSION hold.
var Version = "unknown"

// Proto is the client/agent protocol number the server's info answer carries (proto=): tando-agent
// prints it, and so do tando-status (which answers info for the agent) and tando-gate (which
// answers info for a deploy key). The client refuses a server below the number it needs
// (lib/common.sh PROTO_NEED); raise it together with server/tando-agent's echo "proto=N".
const Proto = "2"
