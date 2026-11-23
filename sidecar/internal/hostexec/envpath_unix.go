//go:build !windows

package hostexec

// RefreshPath: nothing to do here (the login shell's PATH is the user's).
func RefreshPath() {}
