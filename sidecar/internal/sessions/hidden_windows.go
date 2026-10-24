//go:build windows

package sessions

import "golang.org/x/sys/windows"

// isHidden: Explorer's hidden or system attribute (AppData, …).
func isHidden(p string) bool {
	u, err := windows.UTF16PtrFromString(p)
	if err != nil {
		return false
	}
	a, err := windows.GetFileAttributes(u)
	if err != nil {
		return false
	}
	return a&(windows.FILE_ATTRIBUTE_HIDDEN|windows.FILE_ATTRIBUTE_SYSTEM) != 0
}
