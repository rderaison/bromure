//go:build !windows

package pty

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	cpty "github.com/creack/pty"
)

// Process is a program on a pty, leading its own session.
type Process struct {
	info
	cmd  *exec.Cmd
	ptmx *os.File

	done     chan struct{}
	exitCode int

	closeOnce sync.Once
	closed    chan struct{}
}

// Start runs spec on a new pty.
func Start(spec Spec) (*Process, error) {
	env := spec.Env
	if env == nil {
		env = os.Environ()
	}
	var cmd *exec.Cmd
	switch {
	case spec.Cmdline != "":
		cmd = exec.Command("/bin/sh", "-c", spec.Cmdline)
	case len(spec.Argv) > 0 && spec.Argv[0] != "":
		path, err := LookPath(spec.Argv[0], env, spec.Dir)
		if err != nil {
			return nil, err
		}
		cmd = exec.Command(path, spec.Argv[1:]...)
		cmd.Args[0] = spec.Argv[0]
	default:
		return nil, ErrNoCommand
	}
	cmd.Env = env
	cmd.Dir = spec.Dir
	cols, rows := spec.size()
	// StartWithSize: Setsid + Setctty, the pty is the child's controlling tty.
	ptmx, err := cpty.StartWithSize(cmd, &cpty.Winsize{Cols: uint16(cols), Rows: uint16(rows)})
	if err != nil {
		return nil, fmt.Errorf("pty: start: %w", err)
	}
	p := &Process{cmd: cmd, ptmx: ptmx, done: make(chan struct{}), closed: make(chan struct{})}
	p.pid = cmd.Process.Pid
	p.started = time.Now()
	go p.wait()
	return p, nil
}

func (p *Process) wait() {
	err := p.cmd.Wait()
	code := 0
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
				code = 128 + int(ws.Signal())
			} else {
				code = ee.ExitCode()
			}
		} else {
			code = -1
		}
	}
	p.exitCode = code
	close(p.done)
}

// Read reads the pty's output (EIO after the last writer is gone = EOF).
func (p *Process) Read(b []byte) (int, error) {
	n, err := p.ptmx.Read(b)
	if err != nil && (errors.Is(err, syscall.EIO) || errors.Is(err, os.ErrClosed)) {
		err = io.EOF
	}
	return n, err
}

// Write sends input to the pty.
func (p *Process) Write(b []byte) (int, error) { return p.ptmx.Write(b) }

// Resize changes the pty size (the program gets SIGWINCH).
func (p *Process) Resize(cols, rows int) error {
	s := Spec{Cols: cols, Rows: rows}
	c, r := s.size()
	return cpty.Setsize(p.ptmx, &cpty.Winsize{Cols: uint16(c), Rows: uint16(r)})
}

// Wait blocks until the root child exits; its exit code (128+signal when
// killed by one).
func (p *Process) Wait() int {
	<-p.done
	return p.exitCode
}

// Done is closed when the root child has exited.
func (p *Process) Done() <-chan struct{} { return p.done }

// Kill sends SIGKILL to the session's process group and every descendant.
func (p *Process) Kill() error {
	pids := p.Pids()
	_ = syscall.Kill(-p.pid, syscall.SIGKILL)
	for _, pid := range pids {
		if pid != p.pid {
			_ = syscall.Kill(pid, syscall.SIGKILL)
		}
	}
	select {
	case <-p.done:
		return nil
	default:
	}
	return p.cmd.Process.Kill()
}

// Pids lists the root child and its descendants.
func (p *Process) Pids() []int {
	select {
	case <-p.done:
		return nil
	default:
	}
	out, err := exec.Command("ps", "-A", "-o", "pid=,ppid=").Output()
	if err != nil {
		return []int{p.pid}
	}
	children := map[int][]int{}
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) < 2 {
			continue
		}
		pid, e1 := strconv.Atoi(f[0])
		ppid, e2 := strconv.Atoi(f[1])
		if e1 == nil && e2 == nil {
			children[ppid] = append(children[ppid], pid)
		}
	}
	var res []int
	var walk func(int)
	seen := map[int]bool{}
	walk = func(pid int) {
		if seen[pid] {
			return
		}
		seen[pid] = true
		res = append(res, pid)
		for _, c := range children[pid] {
			walk(c)
		}
	}
	walk(p.pid)
	return res
}

// Close closes the pty (the session gets SIGHUP) and kills what is left.
func (p *Process) Close() error {
	p.closeOnce.Do(func() {
		close(p.closed)
		select {
		case <-p.done:
		default:
			_ = p.Kill()
		}
		_ = p.ptmx.Close()
	})
	return nil
}

// LookPath finds name on env's PATH (a name with a slash is used as is,
// relative to dir).
func LookPath(name string, env []string, dir string) (string, error) {
	isExec := func(p string) bool {
		fi, err := os.Stat(p)
		return err == nil && !fi.IsDir() && fi.Mode()&0o111 != 0
	}
	if strings.Contains(name, "/") {
		p := name
		if !filepath.IsAbs(p) && dir != "" {
			p = filepath.Join(dir, p)
		}
		if isExec(p) {
			return p, nil
		}
		return "", fmt.Errorf("pty: %s: not found", name)
	}
	pathVar, ok := envLookup(env, "PATH", false)
	if !ok {
		pathVar = "/usr/local/bin:/usr/bin:/bin"
	}
	for _, d := range filepath.SplitList(pathVar) {
		if d == "" {
			d = "."
		}
		if !filepath.IsAbs(d) && dir != "" {
			d = filepath.Join(dir, d)
		}
		if p := filepath.Join(d, name); isExec(p) {
			return p, nil
		}
	}
	return "", fmt.Errorf("pty: %s: not found on PATH", name)
}
