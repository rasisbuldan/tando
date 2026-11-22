package studio

import (
	"errors"
	"net"
	"net/url"
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
//
// The service's helper (service.go starts it as the app's user):
//
//	serve --fd --app APP --host NAME --admin USER --port N --idle-s SECONDS [--env FILE]
//
// listens on the socket passed as fd 3, reads the app's DATABASE_URL from its env file
// (/opt/tando/apps/<app>/env; --env for tests) and has no heartbeat (stdin's EOF still ends it).
type Args struct {
	Sock, Cred string
	FD         bool   // the listener is fd 3 (the service's helper)
	Env        string // the app's env file (the helper's credential)
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
		if len(a) == 1 && a[0] == "--fd" {
			r.FD, r.Cfg.Heartbeat, a = true, 0, nil
			break
		}
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
		case "--fd":
			r.FD, r.Cfg.Heartbeat = true, 0
			a = append([]string{v}, a...) // (a flag without a value)
			continue
		case "--env":
			r.Env, anySock = v, true
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
	case r.FD && r.Sock != "":
		return r, errors.New("--fd or --sock, not both")
	case !r.FD && !sockRe.MatchString(r.Sock) && !(anySock && strings.HasSuffix(r.Sock, "/s")):
		return r, errors.New("bad socket path")
	}
	if r.FD && r.Env == "" {
		r.Env = "/opt/tando/apps/" + r.Cfg.App + "/env"
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

// Role: the app's PostgreSQL role and database (tando_<app>, - as _)
func Role(app string) string { return "tando_" + strings.ReplaceAll(app, "-", "_") }

// ParseEnvCred reads the app's env file (KEY="value" lines, \ escapes; the agent's env_save) for
// DATABASE_URL, postgres://<role>:<password>@...: the helper's credential. The role must be the
// app's own (Role): an env edited to name another role is refused. A database on a data node
// (DATABASE_URL_DIRECT names another host than the loopback) is reached there, at PostgreSQL's
// own port, only with sslmode=verify-full and its sslrootcert (docs/DATA-NODE.md).
func ParseEnvCred(b []byte, app string, c *Config) error {
	vals := map[string]string{}
	for _, l := range strings.Split(string(b), "\n") {
		k, v, ok := strings.Cut(l, "=")
		if !ok || (k != "DATABASE_URL" && k != "DATABASE_URL_DIRECT") {
			continue
		}
		v = strings.TrimSuffix(strings.TrimPrefix(v, `"`), `"`)
		var o strings.Builder
		for i := 0; i < len(v); i++ {
			if v[i] == '\\' && i+1 < len(v) {
				i++
			}
			o.WriteByte(v[i])
		}
		if _, seen := vals[k]; !seen {
			vals[k] = o.String()
		}
	}
	u, ok := vals["DATABASE_URL"]
	if !ok {
		return errors.New("no DATABASE_URL in the app's env (tando db url)")
	}
	rest, ok := strings.CutPrefix(u, "postgres://")
	if !ok {
		rest, ok = strings.CutPrefix(u, "postgresql://")
	}
	userinfo, _, found := strings.Cut(rest, "@")
	if !ok || !found {
		return errors.New("no DATABASE_URL in the app's env (tando db url)")
	}
	c.Role, c.Password, _ = strings.Cut(userinfo, ":")
	c.Database = c.Role
	if c.Role != Role(app) {
		return errors.New("DATABASE_URL in the app's env names another role than the app's")
	}
	if !roleRe.MatchString(c.Role) || c.Password == "" || strings.ContainsAny(c.Password, "\x00\r") {
		return errors.New("no DATABASE_URL in the app's env (tando db url)")
	}
	if d, ok := vals["DATABASE_URL_DIRECT"]; ok {
		return remoteAddr(d, c)
	}
	return nil
}

// remoteAddr: where DATABASE_URL_DIRECT says the database is, when not on the loopback
func remoteAddr(d string, c *Config) error {
	pu, err := url.Parse(d)
	if err != nil || (pu.Scheme != "postgres" && pu.Scheme != "postgresql") {
		return errors.New("DATABASE_URL_DIRECT in the app's env cannot be read")
	}
	if pu.User.Username() != c.Role {
		return errors.New("DATABASE_URL_DIRECT in the app's env names another role than the app's")
	}
	h := pu.Hostname()
	if h == "127.0.0.1" || h == "localhost" || h == "::1" || h == "" {
		return nil
	}
	q := pu.Query()
	if q.Get("sslmode") != "verify-full" || !strings.HasPrefix(q.Get("sslrootcert"), "/") {
		return errors.New("the database is on another server (" + h + ") and its URL does not ask for sslmode=verify-full with an sslrootcert: the studio does not connect without it")
	}
	port := pu.Port()
	if port == "" {
		port = "5432"
	}
	c.PGAddr, c.PGServerName, c.PGRootCert = net.JoinHostPort(h, port), h, q.Get("sslrootcert")
	return nil
}
