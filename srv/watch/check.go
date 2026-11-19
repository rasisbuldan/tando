package watch

// A check judges facts of this tick and calls tick.sample with ok, bad or hold. Checks run in a
// fixed order because earlier ones decide what later ones may judge: Caddy down holds every
// health probe; an app that deploys, is stopped or whose unit is down is held for memory,
// restarts and health ("a dead app gives one alert, not four").

// hostCheck judges the host, or all apps at once (the health probes and the log scan run as one
// batch for every app).
type hostCheck interface {
	name() string
	check(t *tick)
}

// appCheck judges one app.
type appCheck interface {
	name() string
	check(t *tick, a *appTick)
}

type hostFunc struct {
	id string
	fn func(*tick)
}

func (c hostFunc) name() string  { return c.id }
func (c hostFunc) check(t *tick) { c.fn(t) }

type appFunc struct {
	id string
	fn func(*tick, *appTick)
}

func (c appFunc) name() string              { return c.id }
func (c appFunc) check(t *tick, a *appTick) { c.fn(t, a) }

// before the apps: Caddy (every app is reached through it), its config, and the OOM counters of
// the slices (whose rise is attributed to apps or to the host).
func firstChecks() []hostCheck {
	return []hostCheck{
		hostFunc{"caddy", checkCaddy},
		hostFunc{"caddy_config", checkCaddyConfig},
		hostFunc{"oom slices", checkOOMSlices},
		hostFunc{"postgres", checkPostgres}, // one question for every app with a database; they judge its answer below
	}
}

// for each app with a release, in this order.
func appCheckList() []appCheck {
	return []appCheck{
		appFunc{"stuck", checkStuck},            // also: an activation alive holds the app
		appFunc{"restart count", countRestarts}, // NRestarts since the last run, how it last ended
		appFunc{"down", checkDown},              // not running holds the app for what follows
		appFunc{"restarts", checkRestarts},
		appFunc{"oom", checkOOM},
		appFunc{"memory", checkMemory},
		appFunc{"backup", checkBackup},
		appFunc{"jobs", checkJobs},        // its scheduled jobs: how each last ended (not held with the app)
		appFunc{"db conns", checkDBConns}, // its database role's connections against the role's limit
		appFunc{"disk", checkAppDisk},     // and the disk guard
		appFunc{"uptime class", classify},
		appFunc{"health queue", queueProbe}, // probed together below
		appFunc{"tls", checkTLS},
	}
}

// after the apps: the probes and the log scan of every app at once, then the host.
func lastChecks() []hostCheck {
	return []hostCheck{
		hostFunc{"health", checkHealth}, // and liveness
		hostFunc{"logscan", checkLogscan},
		hostFunc{"uptime", recordUptime},
		hostFunc{"jobs gone", dropJobs}, // alerts of jobs that are no longer scheduled
		hostFunc{"host disk", checkHostDisk},
		hostFunc{"firewall", checkFirewall},
		hostFunc{"host memory", checkHostMemory}, // memory, swap, load
		hostFunc{"host oom", checkHostOOM},
		hostFunc{"hostcare", checkHostcare}, // tando-host's findings (updates, reboot, exposed ports, ...)
		hostFunc{"monitor", checkMonitor},   // tandod itself
	}
}
