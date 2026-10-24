//go:build windows

package netmon

import (
	"sync"

	"golang.org/x/sys/windows"
)

const notifySupported = true

var (
	cbOnce sync.Once
	cbPtr  uintptr
	cbMu   sync.Mutex
	cbKick = map[uintptr]func(){}
	cbNext uintptr
)

// startNotify registers NotifyIpInterfaceChange (any family); every
// interface add/delete/parameter change kicks the monitor.
func startNotify(kick func()) func() {
	cbOnce.Do(func() {
		cbPtr = windows.NewCallback(func(ctx uintptr, row uintptr, typ uintptr) uintptr {
			cbMu.Lock()
			f := cbKick[ctx]
			cbMu.Unlock()
			if f != nil {
				f()
			}
			return 0
		})
	})
	cbMu.Lock()
	cbNext++
	id := cbNext
	cbKick[id] = kick
	cbMu.Unlock()
	var h windows.Handle
	// The context is an opaque token, not a Go pointer.
	if err := windows.NotifyIpInterfaceChange(windows.AF_UNSPEC, cbPtr, unsafePointer(id), false, &h); err != nil {
		cbMu.Lock()
		delete(cbKick, id)
		cbMu.Unlock()
		return func() {}
	}
	return func() {
		_ = windows.CancelMibChangeNotify2(h)
		cbMu.Lock()
		delete(cbKick, id)
		cbMu.Unlock()
	}
}
