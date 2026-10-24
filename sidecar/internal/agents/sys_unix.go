//go:build !windows

package agents

import "os/exec"

func hideWindow(cmd *exec.Cmd) {}
