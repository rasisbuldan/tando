package main

import "os/exec"

// another file of the same package: not excepted
func other() error { return exec.Command("ls").Run() }
