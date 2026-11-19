//go:build windows

package hostexec

import (
	"os/exec"
	"syscall"

	"github.com/rderaison/bromure/sidecar/internal/winutil"
)

// No console window flashes up for a helper the daemon runs.
const createNoWindow = 0x08000000

func prepare(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
}

type procTree struct{ job *winutil.Job }

func track(cmd *exec.Cmd) procTree {
	j, err := winutil.NewJob()
	if err != nil {
		return procTree{}
	}
	if err := j.Assign(cmd.Process); err != nil {
		j.Close()
		return procTree{}
	}
	return procTree{job: j}
}

func (t procTree) kill() {
	if t.job != nil {
		_ = t.job.Kill()
	}
}

func (t procTree) close() {
	if t.job != nil {
		_ = t.job.Close()
	}
}
