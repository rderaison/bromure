// Package pty starts a program on a pseudoconsole: ConPTY on Windows, a
// pty (creack/pty, new session) elsewhere. The caller reads the console's
// output with Read (it must keep reading until io.EOF: a ConPTY blocks its
// program, and its own shutdown, while output is undrained) and writes its
// input with Write.
//
// After the program exits, Read keeps returning buffered output; on Windows
// it reaches io.EOF only once Close is called (the pseudoconsole outlives
// its client). Close releases everything and kills what is left of the
// process tree.
package pty

import (
	"errors"
	"time"
)

// Spec is what to run.
type Spec struct {
	// Argv is the program and its arguments; argv[0] is looked up on the
	// PATH found in Env (PATHEXT honoured on Windows).
	Argv []string
	// Cmdline, when set, wins over Argv: on Windows it is passed to
	// CreateProcess verbatim; elsewhere it is run by /bin/sh -c.
	Cmdline string
	// Env is the complete environment ("K=V"); nil inherits this process's.
	Env []string
	// Dir is the working folder ("" = this process's).
	Dir string
	// Cols and Rows are the console size (default 80x24).
	Cols, Rows int
}

// ErrNoCommand is returned for a Spec with neither Argv nor Cmdline.
var ErrNoCommand = errors.New("pty: no command")

func (s Spec) size() (int, int) {
	c, r := s.Cols, s.Rows
	if c <= 0 {
		c = 80
	}
	if r <= 0 {
		r = 24
	}
	if c > 32767 {
		c = 32767
	}
	if r > 32767 {
		r = 32767
	}
	return c, r
}

// envLookup returns the last value of key in env (case-insensitive on
// Windows), and whether it was there.
func envLookup(env []string, key string, fold bool) (string, bool) {
	val, ok := "", false
	for _, kv := range env {
		i := indexEq(kv)
		if i <= 0 {
			continue
		}
		k := kv[:i]
		if k == key || (fold && equalFold(k, key)) {
			val, ok = kv[i+1:], true
		}
	}
	return val, ok
}

func indexEq(s string) int {
	// "=C:=C:\x" style entries start with '='; skip the first byte.
	for i := 1; i < len(s); i++ {
		if s[i] == '=' {
			return i
		}
	}
	return -1
}

func equalFold(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := 0; i < len(a); i++ {
		x, y := a[i], b[i]
		if 'a' <= x && x <= 'z' {
			x -= 32
		}
		if 'a' <= y && y <= 'z' {
			y -= 32
		}
		if x != y {
			return false
		}
	}
	return true
}

// info is shared by both implementations.
type info struct {
	pid     int
	started time.Time
}

// Pid is the root child's process id.
func (p *Process) Pid() int { return p.pid }

// StartedAt is when the root child started.
func (p *Process) StartedAt() time.Time { return p.started }
