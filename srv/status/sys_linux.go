package status

import (
	"fmt"
	"net/netip"
	"os"
	"syscall"
	"unsafe"

	"tando/srv/internal/fsinfo"
)

// fileID is the identity of a file for the tool cache: device, inode, size, mtime and ctime
// (a package upgrade replaces the file, a hand edit changes the times).
func fileID(fi os.FileInfo) string {
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return fmt.Sprintf("%d:%d", fi.Size(), fi.ModTime().UnixNano())
	}
	return fmt.Sprintf("%d:%d:%d:%d.%d:%d.%d", st.Dev, st.Ino, st.Size, st.Mtim.Sec, st.Mtim.Nsec, st.Ctim.Sec, st.Ctim.Nsec)
}

// netInfo is what `ip -o route get 1.1.1.1` (its src) and `ip -o addr show scope global` (each
// address without its prefix length) printed. The source address of the route is the local
// address a UDP socket connected to 1.1.1.1 gets (connect sends nothing); the addresses come
// from one netlink dump, listed per link in the order of the link dump, as ip lists them.
func netInfo() (string, []string) {
	return routeSrc(), globalAddrs()
}

func routeSrc() string {
	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_DGRAM|syscall.SOCK_CLOEXEC, 0)
	if err != nil {
		return ""
	}
	defer syscall.Close(fd)
	if err := syscall.Connect(fd, &syscall.SockaddrInet4{Port: 53, Addr: [4]byte{1, 1, 1, 1}}); err != nil {
		return ""
	}
	sa, err := syscall.Getsockname(fd)
	if err != nil {
		return ""
	}
	if a, ok := sa.(*syscall.SockaddrInet4); ok {
		return netip.AddrFrom4(a.Addr).String()
	}
	return ""
}

func globalAddrs() []string {
	links, err := syscall.NetlinkRIB(syscall.RTM_GETLINK, syscall.AF_UNSPEC)
	if err != nil {
		return nil
	}
	lm, err := syscall.ParseNetlinkMessage(links)
	if err != nil {
		return nil
	}
	var order []int32
	for _, m := range lm {
		if m.Header.Type == syscall.RTM_NEWLINK && len(m.Data) >= syscall.SizeofIfInfomsg {
			ifi := (*syscall.IfInfomsg)(unsafe.Pointer(&m.Data[0]))
			order = append(order, ifi.Index)
		}
	}
	rib, err := syscall.NetlinkRIB(syscall.RTM_GETADDR, syscall.AF_UNSPEC)
	if err != nil {
		return nil
	}
	am, err := syscall.ParseNetlinkMessage(rib)
	if err != nil {
		return nil
	}
	type addr struct {
		index int32
		text  string
	}
	var all []addr
	for _, m := range am {
		if m.Header.Type != syscall.RTM_NEWADDR || len(m.Data) < syscall.SizeofIfAddrmsg {
			continue
		}
		ifa := (*syscall.IfAddrmsg)(unsafe.Pointer(&m.Data[0]))
		if ifa.Scope != syscall.RT_SCOPE_UNIVERSE {
			continue
		}
		attrs, err := syscall.ParseNetlinkRouteAttr(&m)
		if err != nil {
			continue
		}
		var local, address []byte
		for _, a := range attrs {
			switch a.Attr.Type {
			case syscall.IFA_LOCAL:
				local = a.Value
			case syscall.IFA_ADDRESS:
				address = a.Value
			}
		}
		v := local
		if v == nil {
			v = address
		}
		if ip, ok := netip.AddrFromSlice(v); ok {
			all = append(all, addr{int32(ifa.Index), ip.String()})
		}
	}
	var res []string
	for _, idx := range order {
		for _, a := range all {
			if a.index == idx {
				res = append(res, a.text)
			}
		}
	}
	return res
}

// dfKB is what `df -Pk` prints as 1024-blocks and Used: the sizes in the file system's
// fragment size (f_frsize), rounded up to KiB as GNU df does; used = blocks - free.
func dfKB(path string) (total, used uint64, err error) {
	fs, err := fsinfo.Statfs(path)
	if err != nil {
		return 0, 0, err
	}
	return fs.KiBUp(fs.Blocks), fs.KiBUp(fs.Blocks - fs.Free), nil
}

// machine is `uname -m`.
func machine() string {
	var u syscall.Utsname
	if err := syscall.Uname(&u); err != nil {
		return ""
	}
	b := make([]byte, 0, len(u.Machine))
	for _, ch := range u.Machine {
		if ch == 0 {
			break
		}
		b = append(b, byte(ch))
	}
	return string(b)
}
