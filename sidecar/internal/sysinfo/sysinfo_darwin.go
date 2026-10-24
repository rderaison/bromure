//go:build darwin

package sysinfo

import (
	"time"

	"golang.org/x/sys/unix"
)

func bootTime() float64 {
	tv, err := unix.SysctlTimeval("kern.boottime")
	if err != nil {
		return 0
	}
	return float64(tv.Sec) + float64(tv.Usec)/1e6
}

// Uptime is time since boot.
func Uptime() time.Duration {
	b := bootTime()
	if b <= 0 {
		return 0
	}
	return time.Duration((float64(time.Now().UnixNano())/1e9 - b) * float64(time.Second))
}

func memoryBytes() uint64 {
	n, err := unix.SysctlUint64("hw.memsize")
	if err != nil {
		return 0
	}
	return n
}
