package status

import (
	"strings"

	"tando/srv/internal/decimal"
)

// AppFacts is what one app row is made of.
type AppFacts struct {
	Name  string
	Conf  kv                // app.conf
	State kv                // state
	Unit  map[string]string // systemctl show of tando-<app>.service (nil: no answer)
	Mem   int64             // anon + shmem of the unit's cgroup
	// Logs are tando-logs log-stats' four words (bytes on disk, journal cap, lines in 24 h, lines
	// per hour); nil: none ("- - - -").
	Logs []string
}

// AppRow is the agent's app_row:
//
//	row app "$A" "$state" "${C[port]}" "${S[current]:-}" "${S[status_${S[current]:-x}]:-}" \
//	  "$mem" "$max" "$cpu" "${_u[NRestarts]:-0}" "$up" "$(link)" "${C[recipe]:-}" \
//	  "${C[backup]:-off}" "${S[last_backup]:-}" "${C[database]:-}" ${LG[$A]:-- - - -} "$(app_domains)" \
//	  "${C[cpu]:--}" "${C[tasks]:-1024}" "${C[max_conns]:-256}" "${C[max_requests]:--}"
//
// uptime is the host's (whole seconds of /proc/uptime), host its host.conf.
func AppRow(f AppFacts, host kv, uptime int64) []string {
	u := f.Unit
	get := func(k, def string) string {
		if v := u[k]; v != "" {
			return v
		}
		return def
	}
	max := get("MemoryMax", "")
	if !decimal.IsDigits(max) {
		max = "0"
	}
	cpu := get("CPUUsageNSec", "0")
	if !decimal.IsDigits(cpu) {
		cpu = "0"
	}
	state := get("ActiveState", "inactive")
	up := int64(0)
	if mono := get("ActiveEnterTimestampMonotonic", "0"); state == "active" && mono != "0" {
		up = uptime - atoi(mono)/1000000
	}
	C, S := f.Conf, f.State
	if C.get("recipe") == "static" { // no unit: served by Caddy
		if S.get("current") != "" {
			state = "active"
		}
	}
	if S.get("down") != "" {
		state = "failed"
	}
	if S.get("stopped") != "" {
		state = "stopped" // stopped by the user (tando stop); inactive = it died
	}
	if S.or("phase", "idle") != "idle" {
		state = "deploying"
	}
	cur := S.get("current")
	row := []string{"app", f.Name, state, C.get("port"), cur, S.get("status_" + orStr(cur, "x")),
		decimal.Itoa(f.Mem), max, cpu, get("NRestarts", "0"), decimal.Itoa(up), link(f.Name, C, host), C.get("recipe"),
		C.or("backup", "off"), S.get("last_backup"), C.get("database")}
	lg := f.Logs
	if lg == nil {
		lg = []string{"-", "-", "-", "-"}
	}
	row = append(row, lg...)
	return append(row, appDomains(C), C.or("cpu", "-"), C.or("tasks", "1024"), C.or("max_conns", "256"),
		C.or("max_requests", "-"))
}

func orStr(s, def string) string {
	if s == "" {
		return def
	}
	return s
}

// link is the agent's link: the app's public URL.
func link(a string, C, H kv) string {
	if cu := C.get("check_url"); cu != "" { // adopted app behind a hand-written Caddy site
		return cu + C.get("path")
	}
	site := a + "." + H.or("apps_domain", "localhost")
	if H.or("tls", "off") == "off" {
		port := ""
		if p := H.get("public_port"); p != "" {
			port = ":" + p
		}
		return "http://" + site + port + C.get("path")
	}
	return "https://" + site + C.get("path")
}

// appDomains is app_domains: the app's own domains (C[domains] is "name|www ..."), comma-separated,
// "-" for none.
func appDomains(C kv) string {
	var o []string
	for _, x := range words(C.get("domains")) {
		o = append(o, beforeLast(x, "|"))
	}
	if len(o) == 0 {
		return "-"
	}
	return strings.Join(o, ",")
}

// beforeLast is ${x%|*}: x without its shortest suffix starting with sep (all of x without one).
func beforeLast(x, sep string) string {
	if i := strings.LastIndex(x, sep); i >= 0 {
		return x[:i]
	}
	return x
}

// afterFirst is ${x#*|}.
func afterFirst(x, sep string) string {
	if i := strings.Index(x, sep); i >= 0 {
		return x[i+len(sep):]
	}
	return x
}
