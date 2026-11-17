//go:build !linux

package gate

import "errors"

// The gate runs on Linux only (fs_linux.go). These let the package build elsewhere for its unit
// tests; none of them is ever used there.

var errNotLinux = errors.New("not supported on this system")

type walkEnt struct {
	node
}

func readTree(string, int64, func(*node)) (*tree, bool, error) { return nil, false, errNotLinux }
func readOwnTree(string, int64) (*tree, error)                 { return nil, errNotLinux }
func measure(string, int64, int64) (int64, int64, error)       { return 0, 0, errNotLinux }
func unlinkLink(string, string) error                          { return errNotLinux }
func chownTree(string, int, int) error                         { return errNotLinux }
func stripSetid(string) error                                  { return errNotLinux }
func removeOwned(string, uint32)                               {}
