//go:build linux

package sockopt

import "golang.org/x/sys/unix"

// TCP_USER_TIMEOUT is in milliseconds.
func setUserTimeout(fd uintptr, secs int) {
	_ = unix.SetsockoptInt(int(fd), unix.IPPROTO_TCP, unix.TCP_USER_TIMEOUT, secs*1000)
}
