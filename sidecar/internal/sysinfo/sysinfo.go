// Package sysinfo is what /state reports about the machine: its boot
// (fixed for the whole boot, sleep included — a client tells a reboot by
// it changing), its uptime, memory and CPUs, and its default name.
package sysinfo

import (
	"os"
	"runtime"
	"strings"
	"sync"
	"time"
)

var (
	bootOnce sync.Once
	bootAt   float64
)

// BootedAt is the machine's boot, epoch seconds (computed once).
func BootedAt() float64 {
	bootOnce.Do(func() {
		bootAt = bootTime()
		if bootAt <= 0 {
			bootAt = float64(time.Now().UnixNano())/1e9 - Uptime().Seconds()
		}
	})
	return bootAt
}

// CPUCount is the logical processors.
func CPUCount() int { return runtime.NumCPU() }

// MemoryGB is physical memory in whole GiB.
func MemoryGB() int { return int(memoryBytes() >> 30) }

// DefaultMachineName is the computer's name with "-native", so it never
// reads as a Bromure AC on the same machine.
func DefaultMachineName() string {
	h, err := os.Hostname()
	if err != nil || h == "" {
		h = runtime.GOOS
	}
	if i := strings.IndexByte(h, '.'); i > 0 {
		h = h[:i]
	}
	return strings.ToLower(h) + "-native"
}

// HostOS is /state's hostOS.
func HostOS() string {
	switch runtime.GOOS {
	case "darwin":
		return "macos"
	default:
		return runtime.GOOS
	}
}
