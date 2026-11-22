package watch

import (
	"strings"
	"testing"
)

// An app node linked to a data node (host.conf db_host=): no psql here, nothing fires about a
// PostgreSQL it does not have; the data node (role=data) asks its own about its projects.
func TestPostgresOnTheDataNode(t *testing.T) {
	f := hostWithDB(t)
	f.write("opt/host.conf", "db_host=data1\ndb_addr=192.0.2.10\n")
	f.pgErr = "psql: error: connection to server failed"
	f.ticks(4)
	if n := len(f.pgCmds); n != 0 {
		t.Errorf("app node with its databases on a data node: %d psql runs, want none", n)
	}
	for _, b := range f.sentBodies() {
		if strings.Contains(b, `"check":"postgres"`) {
			t.Errorf("app node alerted about a local PostgreSQL: %s", b)
		}
	}

	d := newFakeHost(t)
	d.write("opt/host.conf", "role=data\npostgres=yes\n")
	d.write("opt/data/db/shop", "node=app1\npool=5\n")
	d.notifier("hook", "type=webhook\nurl=http://127.0.0.1:9/hook\n")
	d.pg = pgAnswer(2, "tando_shop 10 3")
	d.ticks(2)
	if len(d.pgCmds) == 0 {
		t.Fatal("data node: its PostgreSQL is not asked")
	}
	d.pgErr = "psql: error: connection to server failed"
	d.ticks(4)
	fired := false
	for _, b := range d.sentBodies() {
		fired = fired || strings.Contains(b, pgFiring)
	}
	if !fired {
		t.Error("data node: PostgreSQL down did not fire host postgres")
	}
}
