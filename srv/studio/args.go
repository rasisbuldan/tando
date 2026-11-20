package studio

import (
	"errors"
	"regexp"
	"strings"
	"time"

	"tando/srv/internal/valid"
)

// Args: the serve command line (tando-agent db-studio writes it; nothing secret is in it).
//
//	serve --sock PATH --app APP --host NAME --admin USER --port N --idle MINUTES
//	      [--hb SECONDS] [--idle-s SECONDS] [--timeout SECONDS] [--conn-idle SECONDS]   (tests only)
//	      [--cred FILE] [--pg ADDR]                                 (tests; else $CREDENTIALS_DIRECTORY/db, 127.0.0.1:5432)
type Args struct {
	Sock, Cred string
	Cfg        Config
}

var (
	nameRe = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_.-]{0,31}$`)
	sockRe = regexp.MustCompile(`^/run/tando-studio/[0-9a-f]{32}/s$`)
	roleRe = regexp.MustCompile(`^tando_[a-z][a-z0-9_]{1,25}$`)
)

var errArgs = errors.New("usage: tando-studio serve --sock /run/tando-studio/<sid>/s --app APP --host NAME --admin USER --port N --idle MINUTES | version")

// ParseArgs checks every value; test-only paths are accepted only with test-only flags.
func ParseArgs(a []string) (Args, error) {
	r := Args{Cfg: Config{Heartbeat: 10 * time.Second, StmtLimit: DefaultLimit, PGAddr: "127.0.0.1:5432"}}
	anySock := false
	for len(a) > 0 {
		if len(a) < 2 {
			return r, errArgs
		}
		k, v := a[0], a[1]
		a = a[2:]
		num := func(lo, hi int64) (time.Duration, error) {
			n, ok := valid.Uint(v, lo, hi)
			if !ok {
				return 0, errors.New("bad value for " + k)
			}
			return time.Duration(n), nil
		}
		var err error
		var d time.Duration
		switch k {
		case "--sock":
			r.Sock = v
		case "--app":
			r.Cfg.App = v
		case "--host":
			r.Cfg.Host = v
		case "--admin":
			r.Cfg.Admin = v
		case "--port":
			d, err = num(1024, 65535)
			r.Cfg.Port = int(d)
		case "--idle":
			d, err = num(1, 240)
			r.Cfg.Idle = d * time.Minute
		case "--idle-s":
			d, err = num(1, 14400)
			r.Cfg.Idle = d * time.Second
		case "--hb":
			d, err = num(1, 60)
			r.Cfg.Heartbeat = d * time.Second
		case "--conn-idle":
			d, err = num(1, 3600)
			r.Cfg.ConnIdle = d * time.Second
		case "--timeout":
			d, err = num(1, 30)
			r.Cfg.StmtLimit = d * time.Second
		case "--cred":
			r.Cred, anySock = v, true
		case "--pg":
			r.Cfg.PGAddr, anySock = v, true
		default:
			return r, errArgs
		}
		if err != nil {
			return r, err
		}
	}
	switch {
	case !valid.App(r.Cfg.App):
		return r, errors.New("bad app name")
	case !nameRe.MatchString(r.Cfg.Host) || !nameRe.MatchString(r.Cfg.Admin):
		return r, errors.New("bad host or admin name")
	case r.Cfg.Port == 0 || r.Cfg.Idle == 0:
		return r, errArgs
	case !sockRe.MatchString(r.Sock) && !(anySock && strings.HasSuffix(r.Sock, "/s")):
		return r, errors.New("bad socket path")
	}
	return r, nil
}

// ParseCred reads the credential file the agent wrote (root 0600; systemd hands it to the unit):
// user=, db=, password= lines.
func ParseCred(b []byte, c *Config) error {
	for _, l := range strings.Split(string(b), "\n") {
		k, v, ok := strings.Cut(l, "=")
		if !ok {
			continue
		}
		switch k {
		case "user":
			c.Role = v
		case "db":
			c.Database = v
		case "password":
			c.Password = v
		}
	}
	if !roleRe.MatchString(c.Role) || c.Database != c.Role || c.Password == "" || strings.ContainsAny(c.Password, "\x00\r") {
		return errors.New("the credential file is incomplete")
	}
	return nil
}
