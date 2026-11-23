//go:build windows

package sockopt

import "golang.org/x/sys/windows"

// TCP_MAXRT: seconds of retransmission before the connection is reset.
func setUserTimeout(fd uintptr, secs int) {
	_ = windows.SetsockoptInt(windows.Handle(fd), windows.IPPROTO_TCP, windows.TCP_MAXRT, secs)
}
