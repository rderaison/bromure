//go:build linux

package sysinfo

import (
	"os"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

// Uptime is time since boot.
func Uptime() time.Duration {
	data, err := os.ReadFile("/proc/uptime")
	if err != nil {
		return 0
	}
	f, err := strconv.ParseFloat(strings.Fields(string(data))[0], 64)
	if err != nil {
		return 0
	}
	return time.Duration(f * float64(time.Second))
}

func bootTime() float64 {
	data, err := os.ReadFile("/proc/stat")
	if err != nil {
		return 0
	}
	for _, l := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(l, "btime ") {
			v, _ := strconv.ParseFloat(strings.TrimSpace(l[6:]), 64)
			return v
		}
	}
	return 0
}

func memoryBytes() uint64 {
	var si unix.Sysinfo_t
	if unix.Sysinfo(&si) != nil {
		return 0
	}
	return uint64(si.Totalram) * uint64(si.Unit)
}
