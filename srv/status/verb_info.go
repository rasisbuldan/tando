package status

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"tando/srv/internal/atomicfile"
	"tando/srv/internal/bashread"
	"tando/srv/internal/buildinfo"
	"tando/srv/internal/cksum"
	"tando/srv/internal/run"
)

// SecurePath is the PATH the agent's commands had under sudo (Ubuntu's secure_path): node is in
// /usr/local/bin.
const SecurePath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"

// toolTimeout bounds `python3 -c ...`, `node --version` and `caddy version`.
const toolTimeout = 20 * time.Second

// Info is the verb `info`: what the server has, for the client's checks before a deploy.
//
// python3, node and caddy are asked for their versions only when the program changed since the
// last answer: the answers are kept in Lib/status/tools (root 600) with the identity of the
// program file (device, inode, size, mtime, ctime) and of the dpkg status file (an apt install
// or removal, such as python3-venv, changes it). The rest is read without starting anything:
// uname(2), the agent's checksum, the route and the addresses from netlink.
func (c *Collector) Info(ctx context.Context, w io.Writer) error {
	ctx = ctxOr(ctx)
	H := c.hostConf()
	libc := "glibc"
	if m, _ := filepath.Glob(filepath.Join(c.MuslDir, "ld-musl-*")); len(m) > 0 {
		libc = "musl"
	}
	s := newSink()
	s.kv("version", c.version())
	s.kv("proto", buildinfo.Proto) // (the agent answers info through this program when installed)
	s.kv("arch", machine())
	s.kv("libc", libc)
	tools := c.loadTools()
	if libc == "glibc" { // (the client refuses a prebuilt native module that needs a newer glibc)
		v := c.tool(ctx, tools, "glibc", "getconf", []string{"GNU_LIBC_VERSION"}, func(o string) string {
			if f := strings.Fields(o); len(f) == 2 {
				return f[1]
			}
			return ""
		})
		if v == "no" {
			v = ""
		}
		s.kv("glibc", v)
	}
	s.kv("apps_domain", H.get("apps_domain"))
	s.kv("tls", H.get("tls"))
	s.kv("sum", c.agentSum())
	s.kv("podman", H.or("podman", "no"))
	// lint: allow RL16 python3 -c runs a Python statement, not a shell
	s.kv("python", c.tool(ctx, tools, "python", "python3", []string{"-I", "-c", `import venv, sys; print("%d.%d" % sys.version_info[:2])`}, func(o string) string {
		return strings.TrimRight(o, "\n")
	}))
	s.kv("node", c.tool(ctx, tools, "node", "node", []string{"--version"}, func(o string) string {
		return strings.TrimPrefix(strings.TrimRight(o, "\n"), "v")
	}))
	s.kv("caddy", c.tool(ctx, tools, "caddy", "caddy", []string{"version"}, func(o string) string {
		v := strings.TrimRight(o, "\n")
		if i := strings.IndexByte(v, ' '); i >= 0 {
			v = v[:i]
		}
		return strings.TrimPrefix(v, "v")
	}))
	c.saveTools(tools)
	s.kv("postgres", H.or("postgres", "no"))
	s.kv("public_port", H.get("public_port"))
	src, addrs := "", []string(nil)
	if c.Net != nil {
		src, addrs = c.Net()
	} else {
		src, addrs = netInfo()
	}
	s.kv("ip", src)
	var ab strings.Builder
	for _, a := range addrs { // (awk printed each with a space after it)
		ab.WriteString(a)
		ab.WriteByte(' ')
	}
	s.kv("addrs", ab.String())
	s.kv("domain_tls", domainTLS(H))
	return s.to(w)
}

// version is `cat "$R/VERSION" 2> /dev/null || echo unknown` in $(...): trailing newlines go.
func (c *Collector) version() string {
	b, err := readBounded(filepath.Join(c.Env.Root, "VERSION"), 4096, false)
	if err != nil {
		return "unknown"
	}
	return strings.TrimRight(string(bytes.ReplaceAll(b, []byte{0}, nil)), "\n")
}

// agentSum is `cksum < "$AGENT" | cut -d' ' -f1`.
func (c *Collector) agentSum() string {
	sum, err := cksum.File(c.bin("tando-agent"))
	if err != nil {
		return ""
	}
	return fmt.Sprint(sum)
}

// domainTLS is domain_tls: the TLS of an app's own domains: the host's, but never plain http
// unless asked.
func domainTLS(H kv) string {
	if v := H.get("domain_tls"); v != "" {
		return v
	}
	if H.or("tls", "off") == "internal" {
		return "internal"
	}
	return "auto"
}

// tools are the cached answers: name -> key, answer.
type tools map[string][2]string

func (c *Collector) toolsFile() string { return filepath.Join(c.Env.Lib, "status", "tools") }

func (c *Collector) loadTools() tools {
	t := tools{}
	b, err := readBounded(c.toolsFile(), 64<<10, true)
	if err != nil {
		return t
	}
	for _, l := range bashread.Lines(b) {
		f := strings.SplitN(l, "\t", 3)
		if len(f) == 3 {
			t[f[0]] = [2]string{f[1], f[2]}
		}
	}
	t[""] = [2]string{"loaded", string(b)}
	return t
}

// saveTools writes the cache when it changed (root only: a caller without root asks every time).
func (c *Collector) saveTools(t tools) {
	if c.Env.EUID != 0 {
		return
	}
	var b strings.Builder
	for _, n := range []string{"caddy", "glibc", "node", "python"} {
		if v, ok := t[n]; ok {
			fmt.Fprintf(&b, "%s\t%s\t%s\n", n, v[0], v[1])
		}
	}
	if t[""][1] == b.String() {
		return
	}
	dir := filepath.Dir(c.toolsFile())
	if err := os.Mkdir(dir, 0o700); err != nil && !os.IsExist(err) {
		return
	}
	if fi, err := os.Lstat(dir); err != nil || !fi.IsDir() {
		return
	}
	atomicfile.Write(c.toolsFile(), []byte(b.String()), atomicfile.Mode(0o600))
}

// tool answers for one program: "no" when it is not on SecurePath or fails, else its cleaned
// output; from the cache while the program file and the dpkg status are the same.
func (c *Collector) tool(ctx context.Context, t tools, name, prog string, args []string, clean func(string) string) string {
	path, key := c.lookTool(prog)
	if path == "" {
		delete(t, name)
		return "no"
	}
	if v, ok := t[name]; ok && v[0] == key {
		return v[1]
	}
	o, err := c.Env.Run.Output(ctx, run.Cmd{Argv: append([]string{path}, args...),
		Env: []string{"PATH=" + SecurePath, "LC_ALL=C"}, Timeout: toolTimeout, Stderr: io.Discard})
	ans := "no"
	if err == nil {
		ans = clean(string(o))
	}
	if strings.ContainsAny(ans, "\t\n") {
		delete(t, name) // (not kept: the cache is one line per program)
		return ans
	}
	t[name] = [2]string{key, ans}
	return ans
}

// lookTool finds prog on SecurePath as the shell did, and the identity of the file it runs.
func (c *Collector) lookTool(prog string) (string, string) {
	path := c.ToolPath
	if path == "" {
		path = SecurePath
	}
	for _, d := range filepath.SplitList(path) {
		p := filepath.Join(d, prog)
		fi, err := os.Stat(p)
		if err != nil || !fi.Mode().IsRegular() || fi.Mode().Perm()&0o111 == 0 {
			continue
		}
		return p, p + ":" + fileID(fi) + ":" + c.dpkgID()
	}
	return "", ""
}

func (c *Collector) dpkgID() string {
	fi, err := os.Stat(c.Dpkg)
	if err != nil {
		return "-"
	}
	return fileID(fi)
}
