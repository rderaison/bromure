package pty

import (
	"bytes"
	"io"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

// collector drains a Process's output in the background.
type collector struct {
	mu   sync.Mutex
	buf  bytes.Buffer
	done chan struct{}
}

func collect(p *Process) *collector {
	c := &collector{done: make(chan struct{})}
	go func() {
		defer close(c.done)
		b := make([]byte, 4096)
		for {
			n, err := p.Read(b)
			c.mu.Lock()
			c.buf.Write(b[:n])
			c.mu.Unlock()
			if err != nil {
				return
			}
		}
	}()
	return c
}

func (c *collector) String() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.buf.String()
}

func (c *collector) waitFor(t *testing.T, s string, d time.Duration) {
	t.Helper()
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if strings.Contains(c.String(), s) {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("output never contained %q; got %q", s, c.String())
}

func finish(t *testing.T, p *Process, c *collector) int {
	t.Helper()
	code := make(chan int, 1)
	go func() { code <- p.Wait() }()
	var rc int
	select {
	case rc = <-code:
	case <-time.After(15 * time.Second):
		t.Fatal("process never exited")
	}
	time.Sleep(100 * time.Millisecond)
	p.Close()
	select {
	case <-c.done:
	case <-time.After(10 * time.Second):
		t.Fatal("output never reached EOF after Close")
	}
	return rc
}

func gitBash(t *testing.T) string {
	if runtime.GOOS != "windows" {
		p, err := exec.LookPath("bash")
		if err != nil {
			t.Skip("no bash")
		}
		return p
	}
	for _, p := range []string{`C:\Program Files\Git\bin\bash.exe`, `C:\Program Files\Git\usr\bin\bash.exe`} {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	t.Skip("Git Bash not installed")
	return ""
}

func TestEchoExit(t *testing.T) {
	var spec Spec
	if runtime.GOOS == "windows" {
		spec = Spec{Argv: []string{"cmd.exe", "/c", "echo hi-there& exit /b 3"}, Cols: 80, Rows: 24}
	} else {
		spec = Spec{Argv: []string{"sh", "-c", "echo hi-there; exit 3"}, Cols: 80, Rows: 24}
	}
	p, err := Start(spec)
	if err != nil {
		t.Fatal(err)
	}
	if p.Pid() <= 0 || p.StartedAt().IsZero() {
		t.Fatalf("pid %d started %v", p.Pid(), p.StartedAt())
	}
	c := collect(p)
	rc := finish(t, p, c)
	if rc != 3 {
		t.Errorf("exit code %d, want 3", rc)
	}
	if !strings.Contains(c.String(), "hi-there") {
		t.Errorf("output %q lacks hi-there", c.String())
	}
}

func TestBashInputAndTree(t *testing.T) {
	bash := gitBash(t)
	env := os.Environ()
	p, err := Start(Spec{Argv: []string{bash, "--noprofile", "--norc", "-c",
		`printf 'ready\n'; sleep 30 & read x; printf 'got:%s\n' "$x"; kill %1 2>/dev/null; exit 0`},
		Env: env, Cols: 100, Rows: 30})
	if err != nil {
		t.Fatal(err)
	}
	c := collect(p)
	c.waitFor(t, "ready", 10*time.Second)
	// The background sleep is in the tree.
	var pids []int
	for i := 0; i < 50; i++ {
		if pids = p.Pids(); len(pids) >= 2 {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if len(pids) < 2 {
		t.Errorf("tree pids %v, want the shell and its sleep", pids)
	}
	if err := p.Resize(120, 40); err != nil {
		t.Errorf("resize: %v", err)
	}
	if _, err := p.Write([]byte("abc\r")); err != nil {
		t.Fatal(err)
	}
	c.waitFor(t, "got:abc", 10*time.Second)
	if rc := finish(t, p, c); rc != 0 {
		t.Errorf("exit %d", rc)
	}
}

func TestKillTree(t *testing.T) {
	bash := gitBash(t)
	p, err := Start(Spec{Argv: []string{bash, "--noprofile", "--norc", "-c", "sleep 60 & sleep 60; echo never"}})
	if err != nil {
		t.Fatal(err)
	}
	c := collect(p)
	time.Sleep(500 * time.Millisecond)
	before := p.Pids()
	if err := p.Kill(); err != nil {
		t.Fatal(err)
	}
	finish(t, p, c)
	if strings.Contains(c.String(), "never") {
		t.Error("program ran past the kill")
	}
	if runtime.GOOS == "windows" && len(before) < 2 {
		t.Errorf("tree before kill: %v", before)
	}
}

func TestLookPathMissing(t *testing.T) {
	if _, err := Start(Spec{Argv: []string{"definitely-not-a-program-xyz"}}); err == nil {
		t.Fatal("want an error")
	}
	_ = io.EOF
}
