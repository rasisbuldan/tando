package status

import (
	"context"
	"strings"
	"time"

	"tando/srv/internal/sdbus"
	"tando/srv/internal/systemd"
)

// busTimeout bounds one conversation with systemd over its private bus. An answer takes
// milliseconds; a systemd that leaves a question unanswered (see sdbus.NewConn) must not hold a
// status for long before systemctl answers instead.
const busTimeout = 3 * time.Second

// unitProps are the properties of an app's unit that its row shows, and their D-Bus interfaces.
var unitProps = []sdbus.Prop{
	{Iface: "org.freedesktop.systemd1.Unit", Name: "ActiveState"},
	{Iface: "org.freedesktop.systemd1.Service", Name: "MemoryMax"},
	{Iface: "org.freedesktop.systemd1.Service", Name: "CPUUsageNSec"},
	{Iface: "org.freedesktop.systemd1.Service", Name: "NRestarts"},
	{Iface: "org.freedesktop.systemd1.Unit", Name: "ActiveEnterTimestampMonotonic"},
}

// showUnits asks systemd for props of each unit, one map per unit in their order. As root it
// asks over the private bus (Bus); otherwise, or when that fails, with one `systemctl show`
// (what the shell did). Values that are no number ("infinity", "[not set]", or "" from the bus)
// mean the same to every caller: not there.
func (c *Collector) showUnits(ctx context.Context, units []string, props []sdbus.Prop) ([]map[string]string, error) {
	if c.Env.EUID == 0 && c.Bus != "" {
		if res, err := c.busGet(units, props); err == nil {
			return res, nil
		}
	}
	names := make([]string, len(props))
	for i, p := range props {
		names[i] = p.Name
	}
	return systemd.Show(ctx, c.Env.Run, units, names...)
}

// busGet uses the Collector's connection, dialled on first use; a broken one is dialled again
// once (a long-running caller keeps it between calls; Close drops it).
func (c *Collector) busGet(units []string, props []sdbus.Prop) ([]map[string]string, error) {
	c.busMu.Lock()
	defer c.busMu.Unlock()
	for try := 0; try < 2; try++ {
		if c.bus == nil {
			conn, err := sdbus.Dial(c.Bus, busTimeout)
			if err != nil {
				return nil, err
			}
			c.bus = conn
		}
		c.bus.SetDeadline(time.Now().Add(busTimeout))
		res, err := c.bus.UnitProps(units, props, func(unit, prop string) (string, bool) {
			if prop != "MemoryMax" {
				return "", false
			}
			return memoryMaxFromFile(c.UnitRoot, unit)
		})
		if err == nil {
			return res, nil
		}
		c.bus.Close()
		c.bus = nil
		if try == 1 || isAnswer(err) {
			return nil, err
		}
	}
	return nil, nil
}

// isAnswer: systemd answered with an error (dialling again would not help).
func isAnswer(err error) bool { return strings.Contains(err.Error(), "org.freedesktop") }

// Close drops the connection to systemd, if one is open.
func (c *Collector) Close() error {
	c.busMu.Lock()
	defer c.busMu.Unlock()
	if c.bus == nil {
		return nil
	}
	err := c.bus.Close()
	c.bus = nil
	return err
}

// activeState is `systemctl show -P ActiveState <unit>` ("" when it cannot be asked).
func (c *Collector) activeState(ctx context.Context, unit string) string {
	if res, err := c.showUnits(ctx, []string{unit}, unitProps[:1]); err == nil && len(res) == 1 {
		return res[0]["ActiveState"]
	}
	return ""
}
