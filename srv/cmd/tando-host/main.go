// tando-host: host care, the server itself (docs/HOSTCARE.md). Installed as
// /opt/tando/bin/tando-host (root 755) by `tando host setup`; the client reaches it through
// `tando-agent host <verb> ...`. Every verb needs root.
//
//	tando-host status                    rows for tando host status (collects now)
//	tando-host check [apt]               the hourly check (tando-host.timer): the summary file
//	tando-host doctor                    tando doctor's row (from the last summary)
//	tando-host settings | set            the alert settings of host care (stdin key=value)
//	tando-host care | care-on ... | care-off [updates] [reboot] | care-skip [off]
//	tando-host update-plan [all] | update-apply [all]
//	tando-host reboot-plan [now] [other-sites] | reboot [now] [other-sites] | reboot-result
//	tando-host after-boot                tando-host-boot.service: the apps after a reboot by tando
//	tando-host maintain                  tando-host-window.timer: the maintenance window
//	tando-host install [care=on|off]     host setup: the units, care's default
//	tando-host version
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"tando/srv/hostcare"
	"tando/srv/internal/buildinfo"
	"tando/srv/internal/env"
	"tando/srv/internal/out"
)

var errUsage = errors.New("usage: tando-host status | check [apt] | doctor | settings | set | care | care-on ... | care-off ... | care-skip [off] | " +
	"update-plan [all] | update-apply [all] | reboot-plan ... | reboot ... | reboot-result | after-boot | maintain | install [care=on|off] | version")

func main() {
	syscall.Umask(0o022)
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "tando-host: %s\n", out.Clean(err.Error()))
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		return errUsage
	}
	verb, rest := args[0], args[1:]
	if verb == "version" {
		fmt.Println(buildinfo.Version)
		return nil
	}
	h := hostcare.New(env.OS())
	h.SudoUser = os.Getenv("SUDO_USER")
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	o := out.New(os.Stdout)
	defer o.Flush()
	words := func(max int) error {
		if len(rest) > max {
			return errUsage
		}
		return nil
	}
	var err error
	switch verb {
	case "status":
		if err = words(0); err == nil {
			err = h.Status(ctx, o)
		}
	case "check":
		if err = words(1); err == nil {
			err = h.Check(ctx, o, rest)
		}
	case "doctor":
		err = h.Doctor(o)
	case "settings":
		err = h.ShowSettings(o)
	case "set":
		err = h.Set(o, os.Stdin)
	case "care":
		err = h.Care(o)
	case "care-on":
		err = h.CareOn(ctx, o, rest)
	case "care-off":
		err = h.CareOff(ctx, o, rest)
	case "care-skip":
		err = h.CareSkip(ctx, o, rest)
	case "update-plan":
		err = h.UpdatePlan(ctx, o, rest)
	case "update-apply":
		err = h.UpdateApply(ctx, o, rest)
	case "reboot-plan":
		err = h.RebootPlan(o, rest)
	case "reboot":
		err = h.Reboot(ctx, o, rest)
	case "reboot-result":
		err = h.RebootResult(o)
	case "after-boot":
		err = h.AfterBoot(ctx, o)
	case "maintain":
		err = h.Maintain(ctx, o)
	case "install":
		err = h.Install(ctx, o, rest)
	default:
		return errUsage
	}
	return err
}
