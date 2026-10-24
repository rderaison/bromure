//go:build !windows

package panes

import (
	"os"
	"os/exec"
	"syscall"
)

// spawnHost starts `exe panehost` in its own session (setsid), stdio on
// /dev/null, so it outlives the daemon and its terminal.
func spawnHost(exe string) error {
	cmd := exec.Command(exe, "panehost")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return err
	}
	return cmd.Process.Release()
}

// lockFile takes an exclusive, non-blocking flock held until unlock.
func lockFile(path string) (func(), error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, err
	}
	return func() {
		syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		f.Close()
	}, nil
}
