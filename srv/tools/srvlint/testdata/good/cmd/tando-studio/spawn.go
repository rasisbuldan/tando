package main

import "os/exec"

// the one file outside internal/run that may import os/exec (execImporters)
func spawn(bin string) error { return exec.Command(bin, "serve", "--fd").Start() }
