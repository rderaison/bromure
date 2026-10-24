//go:build windows

package netmon

import "unsafe"

// unsafePointer passes a small integer token through the callback context.
func unsafePointer(id uintptr) unsafe.Pointer {
	return *(*unsafe.Pointer)(unsafe.Pointer(&id))
}
