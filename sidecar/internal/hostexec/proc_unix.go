//go:build !windows

package hostexec

import (
	"os/exec"
	"syscall"
)

func prepare(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

type procTree struct{ pgid int }

func track(cmd *exec.Cmd) procTree { return procTree{pgid: cmd.Process.Pid} }

func (t procTree) kill() {
	if t.pgid > 0 {
		_ = syscall.Kill(-t.pgid, syscall.SIGTERM)
		_ = syscall.Kill(-t.pgid, syscall.SIGKILL)
	}
}

func (t procTree) close() {}
