//go:build windows

package main

import (
	"os/exec"
	"syscall"
)

const (
	detachedProcess        = 0x00000008
	createNewProcessGroup  = 0x00000200
	createBreakawayFromJob = 0x01000000
	createNoWindow         = 0x08000000
)

// spawnDetached starts a program that outlives us, with no console.
func spawnDetached(exe string, args ...string) error {
	cmd := exec.Command(exe, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: detachedProcess | createNewProcessGroup | createBreakawayFromJob,
	}
	if err := cmd.Start(); err != nil {
		// Not allowed to break away from our job: without the flag.
		cmd = exec.Command(exe, args...)
		cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: detachedProcess | createNewProcessGroup}
		if err := cmd.Start(); err != nil {
			return err
		}
	}
	return cmd.Process.Release()
}
