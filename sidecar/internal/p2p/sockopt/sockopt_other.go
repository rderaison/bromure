//go:build !windows && !linux && !darwin

package sockopt

func setUserTimeout(fd uintptr, secs int) {}
