//go:build windows

// Package winutil holds the small Windows-only helpers the daemon and the
// tray share: job objects, the registry bits (URL scheme, Run key, Git for
// Windows), message boxes, the clipboard.
package winutil

import (
	"os"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Job is a kill-on-close job object: everything a command spawns is in it
// and goes with it.
type Job struct{ h windows.Handle }

// NewJob makes a job whose processes all die when it is closed.
func NewJob() (*Job, error) {
	h, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return nil, err
	}
	info := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	info.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if _, err := windows.SetInformationJobObject(h, windows.JobObjectExtendedLimitInformation,
		uintptr(unsafe.Pointer(&info)), uint32(unsafe.Sizeof(info))); err != nil {
		windows.CloseHandle(h)
		return nil, err
	}
	return &Job{h: h}, nil
}

// Assign puts a started process in the job.
func (j *Job) Assign(p *os.Process) error {
	h, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE, false, uint32(p.Pid))
	if err != nil {
		return err
	}
	defer windows.CloseHandle(h)
	return windows.AssignProcessToJobObject(j.h, h)
}

// Kill ends every process in the job.
func (j *Job) Kill() error { return windows.TerminateJobObject(j.h, 1) }

// Close closes the job (and, kill-on-close, whatever still runs in it).
func (j *Job) Close() error { return windows.CloseHandle(j.h) }
