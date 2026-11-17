//go:build !linux

package watch

import "errors"

// nftGen: nftables is Linux's; elsewhere the check always lists the rules.
func nftGen() (uint32, error) { return 0, errors.New("nftables: linux only") }
