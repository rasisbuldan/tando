package run

import (
	"errors"
	"fmt"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// Which programs Exec starts is a closed set, so that the whole of it can be audited:
//
//   - Programs (programs.go) is the allowlist of program basenames. A program is started only when
//     its basename is in it. The list is the same set that tools/srvlint finds in the tree and
//     stores in tools/srvlint/programs.txt (the lint fails when they differ): adding a program is
//     a visible change in three places, reviewed as one.
//   - Whatever the list says, a shell is refused (IsShell), and so is a wrapper that starts
//     whatever its arguments say (denied: env, xargs, find, timeout, ...). The denylist is a second
//     check: adding a shell to Programs by mistake still does not start it.
//   - nice, sudo and systemd-run are allowed because they are used, but they start another
//     program: its name goes through the same checks (innerArgv), and an option this file does
//     not know is refused instead of guessed at.
//   - A name with a path separator must be absolute and clean, in one of allowedDirs, and its
//     basename must be in Programs (so "../x", "./sh" and "/tmp/tando-agent" are refused).

// allowedDirs are the directories a program may be named with: the tando programs and the PATH
// of the root programs (status's SecurePath, watch's cmdEnv, BaseEnv).
var allowedDirs = map[string]bool{
	"/opt/tando/bin": true, "/usr/local/sbin": true, "/usr/local/bin": true,
	"/usr/sbin": true, "/usr/bin": true, "/sbin": true, "/bin": true, "/snap/bin": true,
}

// testPrograms are extra basenames for this package's own tests (echo, cat, ...); only code in
// package run can set it, and it never lifts the shell and wrapper denylist.
var testPrograms []string

var shellNames = map[string]bool{
	"sh": true, "bash": true, "dash": true, "zsh": true, "ksh": true, "ash": true, "mksh": true,
	"yash": true, "posh": true, "fish": true, "csh": true, "tcsh": true, "rbash": true, "rksh": true,
	"rzsh": true, "pdksh": true, "oksh": true, "busybox": true, "elvish": true, "xonsh": true,
}

// denied are programs that are not shells but start whatever their arguments name (or take a
// command string): never started, whatever Programs says.
var denied = map[string]bool{
	"env": true, "xargs": true, "find": true, "timeout": true, "nohup": true, "setsid": true,
	"stdbuf": true, "chroot": true, "su": true, "runuser": true, "flock": true, "watch": true,
	"script": true, "strace": true, "ltrace": true, "nsenter": true, "unshare": true,
	"parallel": true, "doas": true, "start-stop-daemon": true, "run-parts": true, "at": true,
}

var versionSuffix = regexp.MustCompile(`[-_.]?[0-9][0-9.]*$`)

// IsShell reports whether base (a basename, or a path) names a shell: bash, bash5, /bin/dash,
// ksh93, busybox and so on.
func IsShell(name string) bool {
	b := filepath.Base(name)
	return shellNames[b] || shellNames[versionSuffix.ReplaceAllString(b, "")]
}

// Denied reports whether Exec refuses name whatever Programs says (a shell or a wrapper that
// starts what its arguments name).
func Denied(name string) bool {
	b := filepath.Base(name)
	return IsShell(b) || denied[b] || denied[versionSuffix.ReplaceAllString(b, "")]
}

// CheckProgram applies the rules to one program name (Argv[0]); the wrappers' inner program is
// CheckArgv's. The lint calls it on every name it finds in the tree.
func CheckProgram(name string) error {
	if name == "" {
		return errors.New("run: empty program name")
	}
	if strings.ContainsAny(name, "\x00\n") {
		return fmt.Errorf("run: bad program name %q", name)
	}
	base := name
	if strings.Contains(name, "/") {
		if !filepath.IsAbs(name) || filepath.Clean(name) != name || !allowedDirs[filepath.Dir(name)] {
			return fmt.Errorf("run: refusing %s: a path must be absolute, clean and in a system directory", name)
		}
		base = filepath.Base(name)
	}
	if IsShell(base) {
		return fmt.Errorf("run: refusing to start a shell (%s)", name)
	}
	if Denied(base) {
		return fmt.Errorf("run: refusing %s: it starts whatever its arguments name", name)
	}
	if !allowed(base) {
		return fmt.Errorf("run: %s is not in the list of programs (srv/internal/run/programs.go)", name)
	}
	return nil
}

func allowed(base string) bool {
	for _, p := range Programs {
		if p == base {
			return true
		}
	}
	for _, p := range testPrograms {
		if p == base {
			return true
		}
	}
	return false
}

// CheckArgv checks Argv[0] and, for nice, sudo and systemd-run, the program they start.
func CheckArgv(argv []string) error {
	for depth := 0; ; depth++ {
		if len(argv) == 0 {
			return errors.New("run: empty argv")
		}
		if err := CheckProgram(argv[0]); err != nil {
			return err
		}
		parse := wrappers[filepath.Base(argv[0])]
		if parse == nil {
			return nil
		}
		inner, err := parse(argv[1:])
		if err != nil {
			return fmt.Errorf("run: %s: %w", argv[0], err)
		}
		if len(inner) == 0 {
			return fmt.Errorf("run: %s starts no program", argv[0])
		}
		if depth >= 3 {
			return errors.New("run: wrappers nested too deep")
		}
		argv = inner
	}
}

// Wrappers lists the programs that start another program (the lint follows them too).
func Wrappers() []string { return []string{"nice", "sudo", "systemd-run"} }

// Inner returns the program (with its arguments) that the wrapper w started with args starts.
func Inner(w string, args []string) ([]string, error) {
	p := wrappers[w]
	if p == nil {
		return nil, fmt.Errorf("%s is not a wrapper", w)
	}
	return p(args)
}

var wrappers = map[string]func(args []string) ([]string, error){
	"nice":        niceInner,
	"sudo":        sudoInner,
	"systemd-run": systemdRunInner,
}

var niceNum = regexp.MustCompile(`^-?[0-9]+$`)

// nice: `nice [-n N | -N | --adjustment=N] program ...` and nothing else.
func niceInner(args []string) ([]string, error) {
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--":
			return args[i+1:], nil
		case a == "-n":
			if i+1 >= len(args) || !niceNum.MatchString(args[i+1]) {
				return nil, errors.New("-n needs a number")
			}
			i++
		case niceNum.MatchString(a):
		case strings.HasPrefix(a, "--adjustment="):
			if !niceNum.MatchString(a[len("--adjustment="):]) {
				return nil, errors.New("--adjustment needs a number")
			}
		case strings.HasPrefix(a, "-"):
			return nil, fmt.Errorf("option %s is not known here", a)
		default:
			return args[i:], nil
		}
	}
	return nil, nil
}

// sudo: `sudo -n -- program ...`: never a prompt, always root (no -u, -g, -E, -s, -i, -e: those
// would pick another user, keep the environment, or start a shell or an editor), and the program
// after `--` goes through the same checks (env, sh and the like are refused there).
func sudoInner(args []string) ([]string, error) {
	i := 0
	if i < len(args) && (args[i] == "-n" || args[i] == "--non-interactive") {
		i++
	}
	if i >= len(args) || args[i] != "--" {
		return nil, errors.New("only `sudo -n -- program ...` is allowed")
	}
	return args[i+1:], nil
}

// systemd-run: the options of the units tando starts, nothing else. A property may start a
// program (ExecStartPre=, ExecStopPost=, ...) or change what one loads (Environment=LD_PRELOAD=...),
// so the property names are an allowlist (systemdProperties), Exec* is never on it, and an
// environment is only the one assignment that is used.
var (
	sdRunFlags = map[string]bool{"--quiet": true, "--wait": true, "--collect": true, "--no-block": true, "--pipe": true}
	// systemdProperties are the names `systemd-run -p NAME=value` may set: exactly what the call
	// sites of gate (the confined receiver) and watch (description of the transient units) use.
	systemdProperties = map[string]bool{
		"Description": true,
		"User":        true, "Group": true, "UMask": true,
		"Environment":   true, // only systemdEnvironment
		"ProtectSystem": true, "ProtectHome": true, "ProtectProc": true, "ProtectKernelTunables": true,
		"ProtectKernelModules": true, "ProtectControlGroups": true,
		"PrivateTmp": true, "PrivateDevices": true, "PrivateNetwork": true,
		"ReadWritePaths": true, "InaccessiblePaths": true, "IPAddressDeny": true,
		"NoNewPrivileges": true, "RestrictSUIDSGID": true, "RestrictNamespaces": true, "LockPersonality": true,
		"CapabilityBoundingSet": true,
		"MemoryMax":             true, "TasksMax": true, "LimitFSIZE": true, "RuntimeMaxSec": true,
	}
	// systemdEnvironment is the only value Environment= may have.
	systemdEnvironment = "LC_ALL=C"
	unitName           = regexp.MustCompile(`^[A-Za-z0-9:_.@\\-]+$`)
)

// SystemdProperties returns the property names systemd-run may be given (for the lint's report).
func SystemdProperties() []string {
	var l []string
	for k := range systemdProperties {
		l = append(l, k)
	}
	sort.Strings(l)
	return l
}

// CheckSystemdProperty checks one `-p` value, or a constant prefix of it that reaches the "=":
// the name must be on the list, and Environment= must be the one assignment. When the value is
// not known (prefix only) Environment is refused: its value must be a constant.
func CheckSystemdProperty(v string, complete bool) error {
	name, val, ok := strings.Cut(v, "=")
	if !ok {
		return fmt.Errorf("property %q has no constant name up to the =", v)
	}
	if !systemdProperties[name] {
		return fmt.Errorf("property %s is not in the list of allowed properties (internal/run/check.go)", name)
	}
	if name == "Environment" && (!complete || val != systemdEnvironment) {
		return fmt.Errorf("Environment= may only be %s", systemdEnvironment)
	}
	return nil
}

func systemdRunInner(args []string) ([]string, error) {
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--":
			return args[i+1:], nil
		case sdRunFlags[a]:
		case a == "-p":
			if i+1 >= len(args) {
				return nil, errors.New("-p without a value")
			}
			i++
			if err := CheckSystemdProperty(args[i], true); err != nil {
				return nil, err
			}
		case strings.HasPrefix(a, "--unit="):
			if !unitName.MatchString(a[len("--unit="):]) {
				return nil, fmt.Errorf("bad unit name in %s", a)
			}
		case strings.HasPrefix(a, "-"):
			return nil, fmt.Errorf("option %s is not allowed here", a)
		default:
			return args[i:], nil
		}
	}
	return nil, nil
}

// scrubEnv drops from a caller's environment what would make a program load or start something
// else: LD_* and DYLD_* (preloads), the pagers and editors that journalctl, systemctl, visudo,
// crontab and sudo start from the environment, and the like. BaseEnv has none of them and no
// caller sets them; this is the second check at the one place programs start.
func scrubEnv(env []string) []string {
	var out []string
	for _, kv := range env {
		name, _, _ := strings.Cut(kv, "=")
		if badEnv[name] || strings.HasPrefix(name, "LD_") || strings.HasPrefix(name, "DYLD_") || strings.HasPrefix(name, "GCONV_") {
			continue
		}
		out = append(out, kv)
	}
	return out
}

var badEnv = map[string]bool{
	"PAGER": true, "SYSTEMD_PAGER": true, "SYSTEMD_PAGERSECURE": true, "SYSTEMD_LESS": true, "LESS": true, "LESSOPEN": true,
	"EDITOR": true, "VISUAL": true, "SUDO_EDITOR": true, "SYSTEMD_EDITOR": true, "BASH_ENV": true, "ENV": true,
	"IFS": true, "PYTHONPATH": true, "PYTHONSTARTUP": true, "PYTHONHOME": true, "NODE_OPTIONS": true, "NODE_PATH": true,
	"PERL5LIB": true, "PERL5OPT": true, "RSYNC_RSH": true, "RSYNC_CONNECT_PROG": true, "SSH_ASKPASS": true,
	"SYSTEMD_EXEC_PID": true, "NFT_TERM": true, "MAILER": true,
}
