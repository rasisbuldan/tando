package watch

import (
	"encoding/binary"
	"errors"
	"syscall"
	"time"
)

// nftGen asks the kernel for the generation of the nftables ruleset (NFT_MSG_GETGEN over
// netlink): it changes with every change of any rule or table, `nft flush ruleset` included. The
// firewall check runs `nft list` (a fork and some milliseconds of nft) only when the generation
// differs from the one it last found the rules complete at.
func nftGen() (uint32, error) {
	const (
		netlinkNetfilter = 12 // NETLINK_NETFILTER
		subsysNftables   = 10 // NFNL_SUBSYS_NFTABLES
		msgGetGen        = 16 // NFT_MSG_GETGEN
		msgNewGen        = 15 // NFT_MSG_NEWGEN
		attrGenID        = 1  // NFTA_GEN_ID
	)
	fd, err := syscall.Socket(syscall.AF_NETLINK, syscall.SOCK_RAW|syscall.SOCK_CLOEXEC, netlinkNetfilter)
	if err != nil {
		return 0, err
	}
	defer syscall.Close(fd)
	tv := syscall.NsecToTimeval(int64(2 * time.Second))
	syscall.SetsockoptTimeval(fd, syscall.SOL_SOCKET, syscall.SO_RCVTIMEO, &tv)
	if err := syscall.Bind(fd, &syscall.SockaddrNetlink{Family: syscall.AF_NETLINK}); err != nil {
		return 0, err
	}
	// nlmsghdr (16) + nfgenmsg (4)
	req := make([]byte, 20)
	binary.LittleEndian.PutUint32(req[0:], 20)
	binary.LittleEndian.PutUint16(req[4:], subsysNftables<<8|msgGetGen)
	binary.LittleEndian.PutUint16(req[6:], syscall.NLM_F_REQUEST)
	binary.LittleEndian.PutUint32(req[8:], 1) // sequence
	req[16] = syscall.AF_UNSPEC               // nfgen_family; version 0, res_id 0
	if err := syscall.Sendto(fd, req, 0, &syscall.SockaddrNetlink{Family: syscall.AF_NETLINK}); err != nil {
		return 0, err
	}
	buf := make([]byte, 4096)
	for range 8 {
		n, _, err := syscall.Recvfrom(fd, buf, 0)
		if err != nil {
			return 0, err
		}
		msgs, err := syscall.ParseNetlinkMessage(buf[:n])
		if err != nil {
			return 0, err
		}
		for _, m := range msgs {
			switch {
			case m.Header.Type == syscall.NLMSG_ERROR:
				if len(m.Data) >= 4 && int32(binary.LittleEndian.Uint32(m.Data)) != 0 {
					return 0, errors.New("nftables: getgen refused")
				}
			case m.Header.Type == subsysNftables<<8|msgNewGen && len(m.Data) > 4:
				attrs := m.Data[4:] // after the nfgenmsg
				for len(attrs) >= 4 {
					l, typ := int(binary.LittleEndian.Uint16(attrs)), binary.LittleEndian.Uint16(attrs[2:])&0x3fff
					if l < 4 || l > len(attrs) {
						break
					}
					if typ == attrGenID && l >= 8 {
						return binary.BigEndian.Uint32(attrs[4:8]), nil
					}
					attrs = attrs[(l+3)&^3:]
				}
				return 0, errors.New("nftables: no generation id")
			}
		}
	}
	return 0, errors.New("nftables: no answer")
}
