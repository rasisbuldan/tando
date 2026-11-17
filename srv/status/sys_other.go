//go:build !linux

package status

import (
	"fmt"
	"os"
)

// fileID on other systems (the package builds there for its tests).
func fileID(fi os.FileInfo) string { return fmt.Sprintf("%d:%d", fi.Size(), fi.ModTime().UnixNano()) }

func netInfo() (string, []string) { return "", nil }

func dfKB(path string) (uint64, uint64, error) { return 0, 0, nil }

func machine() string { return "" }
