package main

import x "os/exec"

// the excepted file, but under another name
func spawn(bin string) error { return x.Command(bin, "serve").Start() }
