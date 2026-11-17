package daemon

import (
	"net"
	"strconv"
	"time"
)

// Systemd is what systemd told the daemon in its environment, read by main (the package reads
// no environment): where to send notifications and whether it watches us.
type Systemd struct {
	NotifySocket string // $NOTIFY_SOCKET ("": not started by systemd, nothing is sent)
	WatchdogUSec string // $WATCHDOG_USEC: WatchdogSec in microseconds ("": no watchdog)
	WatchdogPID  string // $WATCHDOG_PID: the process the watchdog is for ("": this one)
}

// notifier tells systemd how the daemon is (sd_notify, by hand: one datagram to $NOTIFY_SOCKET).
// READY=1 once the socket listens (Type=notify), STATUS= after every tick (`systemctl show -p
// StatusText tandod` is how tando-watch's dead man's check, run without root, learns when the
// last tick was), WATCHDOG=1 while the scheduler makes progress (WatchdogSec: a hung daemon is
// killed and restarted, and its socket goes, so the timer's fallback runs).
type notifier struct{ addr string }

func (n notifier) send(msg string) {
	if n.addr == "" {
		return
	}
	c, err := net.DialTimeout("unixgram", n.addr, time.Second) // ("@..." is the abstract namespace)
	if err != nil {
		return
	}
	defer c.Close()
	c.SetWriteDeadline(time.Now().Add(time.Second))
	c.Write([]byte(msg))
}

// watchdogInterval is half of WatchdogSec, 0 when there is no watchdog for the process pid.
func (s Systemd) watchdogInterval(pid int) time.Duration {
	if p := s.WatchdogPID; p != "" && p != strconv.Itoa(pid) {
		return 0
	}
	us, err := strconv.ParseInt(s.WatchdogUSec, 10, 64)
	if err != nil || us <= 0 {
		return 0
	}
	return time.Duration(us) * time.Microsecond / 2
}
