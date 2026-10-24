//go:build windows

package panes

import (
	"errors"
	"os"
	"os/exec"
	"syscall"

	"golang.org/x/sys/windows"
)

// spawnHost starts `exe panehost` with no console, in its own process
// group, out of the caller's job when the job allows it (so closing the
// daemon's terminal or job never takes the agents with it).
func spawnHost(exe string) error {
	base := uint32(windows.DETACHED_PROCESS | windows.CREATE_NEW_PROCESS_GROUP)
	for _, flags := range []uint32{base | windows.CREATE_BREAKAWAY_FROM_JOB, base} {
		cmd := exec.Command(exe, "panehost")
		cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: flags, HideWindow: true}
		err := cmd.Start()
		if err == nil {
			return cmd.Process.Release()
		}
		// A job without JOB_OBJECT_LIMIT_BREAKAWAY_OK refuses breakaway.
		if !errors.Is(err, windows.ERROR_ACCESS_DENIED) {
			return err
		}
	}
	return errors.New("access denied")
}

// lockFile takes an exclusive, non-blocking lock held until unlock.
func lockFile(path string) (func(), error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	ol := new(windows.Overlapped)
	if err := windows.LockFileEx(windows.Handle(f.Fd()), windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, ol); err != nil {
		f.Close()
		return nil, err
	}
	return func() {
		windows.UnlockFileEx(windows.Handle(f.Fd()), 0, 1, 0, ol)
		f.Close()
	}, nil
}
