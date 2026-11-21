package watch

import (
	"regexp"
)

// defaults are the settings with their production defaults ("a sample" is one run, once a
// minute), in the order `show` lists them. The descriptions are the shell's; tando alerts set
// shows the keys and values.
var defaults = []struct{ key, def, desc string }{
	{"down_after", "2", "samples with the unit not running or restarting before firing"},
	{"health_fails", "3", "failed health probes in a row before firing"},
	{"health_timeout", "10", "seconds per health probe"},
	{"mem_pct", "90", "app memory (anon+shmem) as % of its MemoryMax"},
	{"mem_for", "5", "samples above mem_pct before firing"},
	{"restarts_max", "3", "automatic restarts within restarts_window minutes before firing"},
	{"restarts_window", "15", "minutes"},
	{"oom_quiet", "30", "minutes without a new OOM kill before an oom alert resolves"},
	{"disk_pct", "90", "% of disk space used on /, /var or /opt/tando"},
	{"inode_pct", "90", "% of inodes used"},
	{"mem_avail_pct", "5", "host MemAvailable below this % of RAM counts as memory pressure"},
	{"psi_pct", "30", "host memory pressure (PSI some avg60, when the kernel has it) at or above this %"},
	{"swap_pct", "80", "% of swap used"},
	{"host_for", "5", "samples for host memory pressure and swap before firing"},
	{"load_pct", "100", "5-minute load average as % of the CPU count"},
	{"load_for", "15", "samples above load_pct before firing"},
	{"tls_pct", "20", "fire when a certificate has less than this % of its lifetime left"},
	{"tls_every", "360", "minutes between certificate checks"},
	{"backup_hours", "50", "hours since the last daily backup before firing"},
	{"disk_every", "10", "minutes between measurements of the disk use of each app (shared/, data, releases) against app_max_mb"},
	{"disk_stop_pct", "95", "an app over app_max_mb is stopped when its file system is this % full (0 = never)"},
	{"liveness", "3", "failed health probes in a row, with the unit of the app running, after which tando-watch restarts the app (at most 3 times an hour, then only alerts); 0 = never"},
	{"stuck_min", "20", "minutes an activation may run before it counts as stuck"},
	{"db_conn_pct", "80", "connections of an app's database role as % of the role's connection limit (PostgreSQL's whole server: % of its usable slots)"},
	{"db_conn_for", "5", "samples at or above db_conn_pct before db_conns (or host postgres) fires"},
	{"deadlock_quiet", "30", "minutes without a new deadlock in an app's database before db_deadlock resolves"},
	{"db_wrap_pct", "50", "% of the 2^31 transaction IDs of an app's database used (age of datfrozenxid) at which db_wrap fires"},
	{"db_wrap_warn_pct", "25", "the same % at which db_wrap_warn (low) fires, below db_wrap_pct"},
	{"http_min", "5", "answers with HTTP 5xx within 5 minutes (real requests, from the request log) before http fires, if also http_pct"},
	{"http_pct", "10", "% of the requests within 5 minutes answered 5xx before http fires"},
	{"slow_ms", "3000", "p95 latency in ms of real requests within a minute above which the minute counts as slow"},
	{"slow_min", "10", "requests a minute needed to judge latency (fewer: not judged)"},
	{"slow_for", "5", "slow minutes in a row before slow fires"},
	{"err_spike", "20", "error events in the app log within 5 minutes before errors fires, if also 5x its usual rate"},
	{"err_new_min", "30", "minutes after a deploy during which an error type never seen before is reported once, naming the release"},
	{"logs_quiet", "15", "minutes without lines dropped by journald before a logs alert resolves"},
	{"include_log_lines", "off", "on: notifications carry log lines (the last lines before a crash, error messages); off: only types, counts and ids (log lines can hold secrets)"},
	{"caddy_every", "5", "minutes between validations of the Caddy config (only after a file under /etc/caddy changed)"},
	{"resolve_after", "2", "good samples in a row before a firing alert resolves"},
	{"sample_seconds", "60", "seconds one sample stands for: a second run within it re-evaluates but does not count again (0: every run counts)"},
	{"remind_hours", "6", "hours between reminders while an alert keeps firing (0 = never)"},
	{"flap_max", "3", "firings within flap_window minutes that count as flapping"},
	{"flap_window", "60", "minutes"},
	{"deploy_grace", "120", "seconds after an activation during which the app is not checked"},
	{"boot_grace", "180", "seconds after the host (systemd) started during which apps are not checked"},
	{"heartbeat_every", "5", "minutes between heartbeat pings (the URL is set with tando alerts heartbeat)"},
	{"notify_reboot", "yes", "yes: one notification when the host has restarted"},
	{"name", "-", "host name used in messages (default: the hostname)"},
}

// The checks that can be turned off ("<check>=off", "<app>.<check>=off"). "logs" is of low
// severity: no high priority in ntfy, "(low)" in the text.
var (
	appChecks  = []string{"down", "health", "memory", "oom", "restarts", "tls", "backup", "stuck", "disk", "http", "slow", "errors", "logs", "job", "worker", "db_conns", "db_deadlock", "db_wrap", "db_wrap_warn"}
	hostChecks = []string{"disk", "inodes", "host_memory", "swap", "load", "host_oom", "caddy", "caddy_config", "firewall", "monitor", "postgres"}
)

func lowSeverity(check string) bool { return check == "logs" || check == "ssh" || check == "db_wrap_warn" }

// textSettings are the settings that are not numbers.
func textSetting(k string) bool {
	return k == "name" || k == "notify_reboot" || k == "include_log_lines"
}

func defaultOf(key string) (string, bool) {
	for _, d := range defaults {
		if d.key == key {
			return d.def, true
		}
	}
	return "", false
}

var nineDigits = regexp.MustCompile(`^[0-9]{1,9}$`)

// settings are the defaults overlaid with /opt/tando/alerts.conf; "<app>.<key>" overrides a key
// for one app.
type settings map[string]string

// loadSettings reads the settings file over the defaults. A missing or unreadable file is no
// settings (the shell's `[[ -r $CONF ]]`).
func loadSettings(path string) settings { return loadSettingsC(nil, path) }

// loadSettingsC reads them through a cache (tandod).
func loadSettingsC(c *Cache, path string) settings {
	s := settings{}
	for _, d := range defaults {
		s[d.key] = d.def
	}
	if s["name"] == "-" {
		s["name"] = ""
	}
	m, err := c.load(path)
	if err != nil {
		return s
	}
	for k, v := range m {
		s[k] = v
	}
	return s
}

// raw is the value for app (its override first), and whether there is one.
func (s settings) raw(key, app string) (string, bool) {
	if app != "" {
		if v, ok := s[app+"."+key]; ok {
			return v, true
		}
	}
	v, ok := s[key]
	return v, ok
}

// num is a numeric setting for app ("" for the host). A malformed value (not 1 to 9 digits)
// falls back to the default; leading zeros are decimal ("08" is 8, not an octal error).
func (s settings) num(key, app string) int64 {
	v, _ := s.raw(key, app)
	if !nineDigits.MatchString(v) {
		v, _ = defaultOf(key)
	}
	return num(v, 0)
}

// str is a text setting (name, notify_reboot, include_log_lines) as it is.
func (s settings) str(key string) string {
	v, _ := s.raw(key, "")
	return v
}

// on: the check is not turned off for app (or the host). An empty value counts as on.
func (s settings) on(check, app string) bool {
	v, ok := s.raw(check, app)
	return !ok || v != "off"
}
