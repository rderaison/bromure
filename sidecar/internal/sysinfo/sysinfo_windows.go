//go:build windows

package sysinfo

import (
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	kernel32             = windows.NewLazySystemDLL("kernel32.dll")
	procGetTickCount64   = kernel32.NewProc("GetTickCount64")
	procGlobalMemoryStat = kernel32.NewProc("GlobalMemoryStatusEx")
)

// Uptime is time since boot (GetTickCount64 counts sleep too).
func Uptime() time.Duration {
	r, _, _ := procGetTickCount64.Call()
	return time.Duration(r) * time.Millisecond
}

// bootTime is derived from the uptime once (the tick count is
// monotonic, so this is stable for the boot to within a millisecond).
func bootTime() float64 {
	return float64(time.Now().UnixNano())/1e9 - Uptime().Seconds()
}

type memoryStatusEx struct {
	Length               uint32
	MemoryLoad           uint32
	TotalPhys            uint64
	AvailPhys            uint64
	TotalPageFile        uint64
	AvailPageFile        uint64
	TotalVirtual         uint64
	AvailVirtual         uint64
	AvailExtendedVirtual uint64
}

func memoryBytes() uint64 {
	var m memoryStatusEx
	m.Length = uint32(unsafe.Sizeof(m))
	r, _, _ := procGlobalMemoryStat.Call(uintptr(unsafe.Pointer(&m)))
	if r == 0 {
		return 0
	}
	return m.TotalPhys
}
