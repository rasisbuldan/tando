package status

import (
	"context"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"tando/srv/internal/decimal"
	"tando/srv/internal/sdbus"
)

// workerProps are the properties of a worker's unit that its row shows.
var workerProps = []sdbus.Prop{
	{Iface: "org.freedesktop.systemd1.Unit", Name: "ActiveState"},
	{Iface: "org.freedesktop.systemd1.Unit", Name: "SubState"},
	{Iface: "org.freedesktop.systemd1.Service", Name: "NRestarts"},
	{Iface: "org.freedesktop.systemd1.Service", Name: "MemoryMax"},
}

// reWorker: a worker name as the agent accepts it.
var reWorker = regexp.MustCompile(`^[a-z][a-z0-9-]{0,20}$`)

// workerNames are the workers of an app.conf (worker.<name> = <command>), sorted as `LC_ALL=C
// sort` does (byte order).
func workerNames(C kv) []string {
	var n []string
	for _, k := range C.order {
		if w, ok := strings.CutPrefix(k, "worker."); ok && !strings.Contains(w, ".") && reWorker.MatchString(w) {
			n = append(n, w)
		}
	}
	sort.Strings(n)
	return n
}

// workerUnit is the agent's worker_unit: tando-<app>_worker-<name>.service.
func workerUnit(app, name string) string { return "tando-" + app + "_worker-" + name + ".service" }

// workerRows is the agent's worker_rows: one row per worker of the live release, after its app
// row: worker <app> <name> <state> <restarts> <memory> <max>.
func (c *Collector) workerRows(ctx context.Context, app string, C, S kv) [][]string {
	names := workerNames(C)
	if len(names) == 0 {
		return nil
	}
	units := make([]string, len(names))
	for i, n := range names {
		units[i] = workerUnit(app, n)
	}
	shown, err := c.showUnits(ctx, units, workerProps)
	if err != nil || len(shown) != len(units) {
		shown = make([]map[string]string, len(units))
	}
	slice := "tando-" + strings.ReplaceAll(app, "-", `\x2d`) + ".slice"
	rows := make([][]string, 0, len(names))
	for i, n := range names {
		u := shown[i]
		st := u["ActiveState"]
		if st == "" {
			st = "inactive"
		}
		if st == "activating" && u["SubState"] == "auto-restart" {
			st = "restarting"
		}
		if S.get("stopped") != "" {
			st = "stopped"
		}
		mem := memAnonShmem(filepath.Join(c.Env.Cgroup, "tando.slice", slice, units[i], "memory.stat"))
		max := u["MemoryMax"]
		if !decimal.IsDigits(max) {
			max = "0"
		}
		nr := u["NRestarts"]
		if !decimal.IsDigits(nr) {
			nr = "0"
		}
		rows = append(rows, []string{"worker", app, n, st, nr, decimal.Itoa(mem), max})
	}
	return rows
}
