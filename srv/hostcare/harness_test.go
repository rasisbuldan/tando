package hostcare

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"tando/srv/internal/env"
	"tando/srv/internal/fsinfo"
	"tando/srv/internal/out"
	"tando/srv/internal/run"
)

// fakeHost is a server in a temp directory: FS (the system's files), Root (/opt/tando), Lib
// (/var/lib/tando), Proc; a clock that only moves when told (or when the code sleeps); a runner
// that records every argv and answers from a table; statfs, adjtimex and the prober replaced.
type fakeHost struct {
	t       *testing.T
	h       *Host
	dir     string
	now     time.Time
	mu      sync.Mutex
	calls   []string
	envs    [][]string
	answer  map[string]string // argv prefix -> stdout
	fail    map[string]bool   // argv prefix -> exit 1
	disks   map[string]fsinfo.FS
	synced  bool
	healthy map[string]bool // app -> its probe answers 200
}

func newFake(t *testing.T) *fakeHost {
	f := &fakeHost{t: t, dir: t.TempDir(), now: time.Date(2026, 11, 17, 10, 0, 0, 0, time.UTC), answer: map[string]string{},
		fail: map[string]bool{}, synced: true, healthy: map[string]bool{}}
	fs, root, lib, proc := f.p("fs"), f.p("root"), f.p("lib"), f.p("proc")
	for _, d := range []string{fs, fs + "/etc/apt/apt.conf.d", fs + "/etc/systemd/system", root + "/bin", root + "/apps", lib + "/watch", proc + "/sys/kernel/random", proc + "/net", proc + "/pressure"} {
		os.MkdirAll(d, 0o755)
	}
	f.disks = map[string]fsinfo.FS{"/": {Blocks: 1000, Free: 600, Avail: 550, Files: 1000, FilesFree: 900, Unit: 1 << 20}}
	h := &Host{
		Env: env.Env{Root: root, Lib: lib, Proc: proc, EUID: 0, Now: func() time.Time { f.mu.Lock(); defer f.mu.Unlock(); return f.now },
			Run: run.Func(f.run)},
		FS: fs, Loc: time.UTC, Stderr: &bytes.Buffer{},
		Statfs: func(p string) (fsinfo.FS, error) {
			if d, ok := f.disks[strings.TrimPrefix(p, fs)]; ok {
				return d, nil
			}
			return fsinfo.FS{}, errors.New("no such file system")
		},
		Adjtimex: func() (bool, bool) { return f.synced, true },
		Sleep:    func(d time.Duration) { f.mu.Lock(); f.now = f.now.Add(d); f.mu.Unlock() },
		Probe:    f,
	}
	f.h = h
	// a plain Ubuntu 24.04 server: captured files where there are some
	f.copy("ubuntu24/os-release", "fs/etc/os-release")
	f.write("fs/etc/passwd", "root:x:0:0:root:/root:/bin/bash\nvmadmin:x:1000:1000::/home/vmadmin:/bin/bash\ntando-shop:x:2000:2000::/opt/tando/apps/shop/home:/usr/sbin/nologin\n")
	f.write("fs/home/vmadmin/.ssh/authorized_keys", "ssh-ed25519 AAAA one\n# comment\nssh-ed25519 AAAA two\n")
	f.write("fs/etc/shadow", "root:*:1::::::\nvmadmin:!:1::::::\n")
	f.write("fs/etc/sudoers.d/vmadmin", "vmadmin ALL=(ALL) NOPASSWD:ALL\n")
	f.write("fs/usr/sbin/sshd", "")
	f.write("fs/usr/bin/apt-get", "")
	f.write("fs/var/lib/dpkg/status", string(fixture(t, "ubuntu24/dpkg-status.txt"))+"\nPackage: unattended-upgrades\nStatus: install ok installed\nVersion: 2.9\n\n")
	f.write("fs/var/lib/apt/lists/archive_dists_noble-security_InRelease", "x")
	f.write("fs/etc/caddy/Caddyfile", "import /etc/caddy/tando/*.caddy\n")
	f.write("root/host.conf", "apps_domain=localhost\ntls=off\ncaddy_installed=yes\n")
	f.write("proc/sys/kernel/hostname", "vps1\n")
	f.write("proc/sys/kernel/osrelease", "6.8.0-51-generic\n")
	f.write("proc/sys/kernel/random/boot_id", "boot-1\n")
	f.write("proc/uptime", "259200.5 1000.0\n")
	f.write("proc/loadavg", "0.10 0.20 0.30 1/100 4242\n")
	f.write("proc/meminfo", "MemTotal: 2000000 kB\nMemAvailable: 1500000 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n")
	f.write("proc/mounts", "/dev/vda1 / ext4 rw,relatime 0 0\nproc /proc proc rw 0 0\n")
	f.write("fs/sys/devices/system/cpu/online", "0-1\n")
	f.copy("ubuntu24/proc-net-tcp.txt", "proc/net/tcp")
	f.copy("ubuntu24/proc-net-tcp6.txt", "proc/net/tcp6")
	f.copy("ubuntu24/proc-net-udp.txt", "proc/net/udp")
	f.copy("ubuntu24/proc-net-udp6.txt", "proc/net/udp6")
	// the processes of the captured sockets: sshd (21151786, 21151788), python on 8765 (21150262)
	f.proc(100, "sshd", "0::/system.slice/ssh.service\n", 21151786, 21151788)
	f.proc(200, "python3", "0::/user.slice/user-1000.slice/session-1.scope\n", 21150262)
	f.answer["/usr/sbin/sshd -T"] = string(fixture(t, "ubuntu24/sshd-T.txt"))
	f.answer["systemctl show -p SystemState"] = "SystemState=running\nNFailedUnits=0\nVirtualization=kvm\n"
	f.answer["systemctl show -p ActiveState"] = f.unitStates(map[string]string{"systemd-timesyncd.service": "active", "apt-daily-upgrade.timer": "active"})
	f.answer["apt-get -s"] = string(fixture(t, "ubuntu24/apt-sim-dist-upgrade.txt"))
	f.answer["apt-config dump"] = strings.Replace(string(fixture(t, "ubuntu24/apt-config-dump.txt")), `APT::Periodic::Enable "0";`, `APT::Periodic::Enable "1";`, 1)
	f.answer["dpkg --audit"] = ""
	f.answer["journalctl"] = ""
	return f
}

func (f *fakeHost) p(rel string) string { return filepath.Join(f.dir, rel) }

func (f *fakeHost) write(rel, s string) {
	p := f.p(rel)
	os.MkdirAll(filepath.Dir(p), 0o755)
	if err := os.WriteFile(p, []byte(s), 0o644); err != nil {
		f.t.Fatal(err)
	}
}

func (f *fakeHost) copy(fix, rel string) { f.write(rel, string(fixture(f.t, fix))) }

// proc makes /proc/<pid> with its comm, cgroup and socket descriptors.
func (f *fakeHost) proc(pid int, comm, cgroup string, inodes ...uint64) {
	d := "proc/" + itoa(pid)
	f.write(d+"/comm", comm+"\n")
	f.write(d+"/cgroup", cgroup)
	f.write(d+"/stat", itoa(pid)+" ("+comm+") S 1 1")
	os.MkdirAll(f.p(d+"/fd"), 0o755)
	for i, ino := range inodes {
		os.Symlink("socket:["+strings.TrimLeft(itoa(int(ino)), "")+"]", f.p(d+"/fd/"+itoa(i+3)))
	}
}

// unitStates answers `systemctl show -p ActiveState <units...>` in the order Collect asks.
func (f *fakeHost) unitStates(m map[string]string) string {
	var b strings.Builder
	units := append(append(append([]string{}, timeUnits...), guardUnits...), otherUnits...)
	for i, u := range units {
		if i > 0 {
			b.WriteString("\n")
		}
		s := m[u]
		if s == "" {
			s = "inactive"
		}
		b.WriteString("ActiveState=" + s + "\n")
	}
	return b.String()
}

func (f *fakeHost) run(_ context.Context, c run.Cmd) ([]byte, error) {
	if err := run.CheckArgv(c.Argv); err != nil {
		f.t.Errorf("not allowed: %v", err)
	}
	a := strings.Join(c.Argv, " ")
	f.mu.Lock()
	f.calls = append(f.calls, a)
	f.envs = append(f.envs, c.Env)
	f.mu.Unlock()
	best := ""
	for k := range f.fail {
		if strings.HasPrefix(a, k) {
			return nil, errors.New(c.Argv[0] + ": exit status 1")
		}
	}
	for k := range f.answer {
		if strings.HasPrefix(a, k) && len(k) > len(best) {
			best = k
		}
	}
	if best == "" {
		return nil, nil
	}
	if c.Stdout != nil {
		c.Stdout.Write([]byte(f.answer[best]))
		return nil, nil
	}
	return []byte(f.answer[best]), nil
}

func (f *fakeHost) Probe(_ context.Context, url string, _ time.Duration) (int, string, error) {
	for a, ok := range f.healthy {
		if strings.Contains(url, "://"+a+".") {
			if ok {
				return 200, "ok", nil
			}
			return 502, "", nil
		}
	}
	return 0, "", errors.New("connection refused")
}

func (f *fakeHost) called(prefix string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, c := range f.calls {
		if strings.HasPrefix(c, prefix) {
			return true
		}
	}
	return false
}

func (f *fakeHost) reset() { f.mu.Lock(); f.calls, f.envs = nil, nil; f.mu.Unlock() }

func (f *fakeHost) advance(d time.Duration) { f.mu.Lock(); f.now = f.now.Add(d); f.mu.Unlock() }

// verb runs a verb and returns its output.
func (f *fakeHost) verb(fn func(o *out.Writer) error) (string, error) {
	var b bytes.Buffer
	o := out.New(&b)
	err := fn(o)
	o.Flush()
	return b.String(), err
}

// check runs the hourly check (apt now) and returns the findings and alerts of the summary.
func (f *fakeHost) check() (map[string]Finding, map[string]Alert) {
	f.t.Helper()
	if _, err := f.verb(func(o *out.Writer) error { return f.h.Check(context.Background(), o, []string{"apt"}) }); err != nil {
		f.t.Fatal(err)
	}
	return f.summary()
}

func (f *fakeHost) summary() (map[string]Finding, map[string]Alert) {
	b, err := os.ReadFile(f.h.SummaryPath())
	if err != nil {
		f.t.Fatal(err)
	}
	fs, as := map[string]Finding{}, map[string]Alert{}
	for _, l := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		p := strings.Split(l, "\t")
		switch p[0] {
		case "finding":
			fs[p[1]] = Finding{ID: p[1], Section: p[2], State: p[3], Auto: p[5] == "1", Title: p[7], Detail: p[8], Fix: p[9]}
		case "alert":
			as[p[1]] = Alert{Check: p[1], State: p[2], Priority: p[4], Detail: p[6]}
		}
	}
	return fs, as
}

func (f *fakeHost) app(name string, conf, state string) {
	f.write("root/apps/"+name+"/app.conf", conf)
	f.write("root/apps/"+name+"/state", state)
}
