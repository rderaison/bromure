//go:build darwin

package sockopt

import "golang.org/x/sys/unix"

// TCP_RXT_CONNDROPTIME, what the Swift sets, is in seconds.
func setUserTimeout(fd uintptr, secs int) {
	_ = unix.SetsockoptInt(int(fd), unix.IPPROTO_TCP, unix.TCP_RXT_CONNDROPTIME, secs)
}
