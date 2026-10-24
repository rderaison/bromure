//go:build !windows

package sessions

func isHidden(p string) bool { return false }
