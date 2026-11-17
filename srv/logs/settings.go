package logs

import (
	"regexp"
	"strconv"
	"strings"
)

// Built-in defaults. log_max 2G is only the upper bound of the default: an app without its own
// log_max (and no host default) gets min(2G, 5% of the log file system), so the defaults of many
// apps cannot fill a small disk (fairShare). The request log's budget (request_log_max) defaults
// to min(log_max / 4, 256M); its retention follows log_keep (access_keep_for at the host
// overrides).
var defaults = map[string]string{"journal_max": "200M", "log_max": "2G", "log_keep": "30d", "log_rate": "5000/30s",
	"access_log": "on", "request_log_max": "auto"}

const fairPct = 5

var (
	reSize  = regexp.MustCompile(`^[0-9]{1,6}[KMG]$`)
	reKeep  = regexp.MustCompile(`^[0-9]{1,4}[hdw]$`)
	reRate  = regexp.MustCompile(`^([0-9]{1,6})/([0-9]{1,4})s$`)
	reMiB   = regexp.MustCompile(`^[0-9]{1,3}$`)
	reFiles = regexp.MustCompile(`^[0-9]{1,2}$`)
)

// Valid checks a log setting, host or app (`tando-logs valid`, used by the agent for tando.conf).
func Valid(k, v string) bool {
	switch k {
	case "journal_max", "log_max", "request_log_max":
		return reSize.MatchString(v) && sizeBytes(v) >= 4194304
	case "log_keep", "access_keep_for":
		n, _ := strconv.ParseInt(v[:max(len(v)-1, 0)], 10, 64)
		return reKeep.MatchString(v) && n >= 1 && keepHours(v) <= 87600
	case "log_rate":
		if v == "off" {
			return true
		}
		m := reRate.FindStringSubmatch(v)
		if m == nil {
			return false
		}
		n, _ := strconv.ParseInt(m[1], 10, 64)
		return n >= 1
	case "access_log":
		return v == "on" || v == "off"
	case "access_size": // MiB per file
		n, _ := strconv.ParseInt(v, 10, 64)
		return reMiB.MatchString(v) && n >= 1
	case "access_keep": // rolled files kept
		return reFiles.MatchString(v)
	}
	return false
}

// sizeBytes: "64M" -> 67108864 (a checked value; leading zeros are decimal).
func sizeBytes(v string) int64 {
	if v == "" {
		return 0
	}
	n, _ := strconv.ParseInt(strings.TrimRight(v, "KMG"), 10, 64)
	switch v[len(v)-1] {
	case 'K':
		return n * 1024
	case 'M':
		return n * 1048576
	case 'G':
		return n * 1073741824
	}
	return n
}

// keepHours: "2d" -> 48.
func keepHours(v string) int64 {
	if v == "" {
		return 0
	}
	n, _ := strconv.ParseInt(v[:len(v)-1], 10, 64)
	switch v[len(v)-1] {
	case 'd':
		return n * 24
	case 'w':
		return n * 168
	}
	return n
}

var (
	reNormRate = regexp.MustCompile(`^([0-9]+)/([0-9]+)s$`)
	reNormNum  = regexp.MustCompile(`^([0-9]+)([A-Za-z]?)$`)
)

// norm: a checked value with its numbers in plain decimal: "08" -> "8", "09d" -> "9d",
// "0500/030s" -> "500/30s" (bash read a leading 0 as octal, and Caddy rejects "roll_keep_for h").
func norm(v string) string {
	if m := reNormRate.FindStringSubmatch(v); m != nil {
		return dec(m[1]) + "/" + dec(m[2]) + "s"
	}
	if m := reNormNum.FindStringSubmatch(v); m != nil {
		return dec(m[1]) + m[2]
	}
	return v
}

func dec(s string) string {
	n, _ := strconv.ParseInt(s, 10, 64)
	return strconv.FormatInt(n, 10)
}

// setting is the effective value for the app: app.conf, then the host defaults, then the
// built-in ones. A stored value that does not pass Valid (an older file, a hand edit) falls back
// to the next level.
func (a *app) setting(k string) string {
	for _, v := range []string{a.conf[k], a.host[k]} {
		if v != "" && Valid(k, v) {
			return norm(v)
		}
	}
	switch k {
	case "log_max":
		return a.l.fairShare()
	case "request_log_max":
		v := sizeBytes(a.setting("log_max")) / 4 / 1048576
		v = min(max(v, 4), 256)
		return strconv.FormatInt(v, 10) + "M"
	case "access_keep_for":
		return a.setting("log_keep")
	}
	return defaults[k]
}

// settingSrc: where the value came from, for status and doctor: app, host or auto.
func (a *app) settingSrc(k string) string {
	if v := a.conf[k]; v != "" && Valid(k, v) {
		return "app"
	}
	if v := a.host[k]; v != "" && Valid(k, v) {
		return "host"
	}
	return "auto"
}

// hostSetting: a host-level value (journal_max) from logs.conf, else the built-in default.
func hostSetting(h map[string]string, k string) string {
	if v := h[k]; v != "" && Valid(k, v) {
		return norm(v)
	}
	return defaults[k]
}

// fairShare is the default journal cap: min(2G, fairPct % of the file system that holds the
// journals), in MB.
func (l *Logs) fairShare() string {
	tot, _, err := diskKB(l.P.VarLog)
	if err != nil {
		return "256M"
	}
	m := tot * fairPct / 100 / 1024
	m = min(max(m, 16), 2048)
	if m == 2048 {
		return "2G"
	}
	return strconv.FormatInt(m, 10) + "M"
}

// roll is the rotation of the request log from its budget (request_log_max, default
// min(log_max/4, 256M)): files of an eighth of it, at most 32 MiB, and as many rolled files as
// fit. Caddy gzips rolled files (about 20x smaller for these lines, measured), so the budget holds
// even if nothing compressed and the history is far longer than the budget suggests. The host
// settings access_size/access_keep (older tando) still win when set.
type roll struct {
	Size, Keep int64 // MiB per file, rolled files kept
	Max        int64 // bytes: Size x (Keep + 1)
}

func (a *app) roll() roll {
	mb := sizeBytes(a.setting("request_log_max")) / 1048576
	r := roll{Size: min(max(mb/8, 1), 32)}
	r.Keep = min(max(mb/r.Size-1, 1), 99)
	if v := a.host["access_size"]; v != "" && Valid("access_size", v) {
		r.Size, _ = strconv.ParseInt(norm(v), 10, 64)
	}
	if v := a.host["access_keep"]; v != "" && Valid("access_keep", v) {
		r.Keep, _ = strconv.ParseInt(norm(v), 10, 64)
	}
	r.Max = r.Size * (r.Keep + 1) * 1048576
	return r
}
