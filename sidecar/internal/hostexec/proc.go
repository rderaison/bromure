package hostexec

import (
	"bytes"
	"context"
	"errors"
	"os/exec"
	"time"
)

// Result is a finished command.
type Result struct {
	Status   int
	Stdout   string
	Stderr   string
	TimedOut bool
}

// ProcSpec is one command to run to completion.
type ProcSpec struct {
	Path    string
	Args    []string // without argv[0]
	Env     []string
	Dir     string
	Stdin   []byte
	Timeout time.Duration
}

// RunProc runs a process to completion with a timeout, capturing both
// streams; on timeout the whole process tree is killed.
func RunProc(s ProcSpec) Result {
	if s.Timeout <= 0 {
		s.Timeout = 30 * time.Second
	}
	if s.Timeout < time.Second {
		s.Timeout = time.Second
	}
	cmd := exec.Command(s.Path, s.Args...)
	cmd.Env = s.Env
	cmd.Dir = s.Dir
	var out, errb bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errb
	if s.Stdin != nil {
		cmd.Stdin = bytes.NewReader(s.Stdin)
	}
	prepare(cmd)
	if err := cmd.Start(); err != nil {
		return Result{Status: 127, Stderr: s.Path + ": " + err.Error()}
	}
	tree := track(cmd)
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	ctx, cancel := context.WithTimeout(context.Background(), s.Timeout)
	defer cancel()
	var err error
	timedOut := false
	select {
	case err = <-done:
	case <-ctx.Done():
		timedOut = true
		tree.kill()
		select {
		case err = <-done:
		case <-time.After(3 * time.Second):
			// A grandchild holding our pipes open: give up on the rest.
			err = errors.New("timed out")
		}
	}
	tree.close()
	status := 0
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			status = ee.ExitCode()
		} else if !timedOut {
			status = 127
		}
	}
	return Result{Status: status, Stdout: out.String(), Stderr: errb.String(), TimedOut: timedOut}
}
