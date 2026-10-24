//go:build !windows

package paths

import "os"

// Protect makes a directory owner-only.
func Protect(path string) error { return os.Chmod(path, 0o700) }

// ProtectFile makes a secret file owner-only.
func ProtectFile(path string) error { return os.Chmod(path, 0o600) }
