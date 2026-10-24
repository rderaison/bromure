package panes

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"syscall"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/paths"
)

// HostInfo asks the running pane host for its protocol version and window
// count (the daemon restarts an older host only when it has no windows).
func HostInfo() (version, windows int, err error) {
	hi, err := hello(paths.PanesSocket())
	if err != nil {
		return 0, 0, err
	}
	return hi.Version, hi.Windows, nil
}

func hello(path string) (HelloInfo, error) {
	c, err := net.DialTimeout("unix", path, 2*time.Second)
	if err != nil {
		return HelloInfo{}, err
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(5 * time.Second))
	b, _ := json.Marshal(&request{Op: "hello", Version: HostVersion})
	if _, err := c.Write(append(b, '\n')); err != nil {
		return HelloInfo{}, err
	}
	var buf []byte
	one := make([]byte, 4096)
	for {
		n, err := c.Read(one)
		buf = append(buf, one[:n]...)
		if i := indexByte(buf, '\n'); i >= 0 {
			buf = buf[:i]
			break
		}
		if err != nil {
			return HelloInfo{}, err
		}
	}
	var resp response
	if err := json.Unmarshal(buf, &resp); err != nil {
		return HelloInfo{}, err
	}
	if !resp.OK {
		return HelloInfo{}, decodeErr(&resp)
	}
	var hi HelloInfo
	err = json.Unmarshal(resp.Result, &hi)
	return hi, err
}

func indexByte(b []byte, c byte) int {
	for i, x := range b {
		if x == c {
			return i
		}
	}
	return -1
}

// StopHost asks the pane host to exit; it refuses while it has windows
// unless force (which kills them).
func StopHost(force bool) error {
	c, err := Connect()
	if err != nil {
		return err
	}
	defer c.Close()
	r := c.(*remote)
	return r.call(&request{Op: "shutdown", Force: force}, nil)
}

// EnsureHost connects to the pane host, starting one first when none
// answers: `<this exe> panehost`, fully detached so it outlives the daemon.
func EnsureHost() (Client, error) {
	if c, err := Connect(); err == nil {
		return c, nil
	}
	if err := paths.Ensure(); err != nil {
		return nil, err
	}
	if err := spawnHost(paths.Executable()); err != nil {
		return nil, fmt.Errorf("panes: starting the pane host: %w", err)
	}
	deadline := time.Now().Add(8 * time.Second)
	var last error
	for time.Now().Before(deadline) {
		c, err := Connect()
		if err == nil {
			return c, nil
		}
		last = err
		time.Sleep(100 * time.Millisecond)
	}
	return nil, fmt.Errorf("panes: the pane host never answered: %w", last)
}

// RunHost is `bromure-sidecar panehost`: serve panes.sock until asked to
// stop. A second instance exits 0 at once.
func RunHost() int {
	if err := paths.Ensure(); err != nil {
		fmt.Fprintln(os.Stderr, "panehost:", err)
		return 1
	}
	sock := paths.PanesSocket()
	if _, err := hello(sock); err == nil {
		return 0 // already running
	}
	unlock, err := lockFile(filepath.Join(paths.DataDir(), "panes.lock"))
	if err != nil {
		// Another pane host holds the lock (starting up, or running): it
		// owns the socket.
		return 0
	}
	defer unlock()
	if _, err := hello(sock); err == nil {
		return 0
	}
	os.Remove(sock)
	l, err := net.Listen("unix", sock)
	if err != nil {
		logx.Printf("panes: listen %s: %v", sock, err)
		return 1
	}
	if runtime.GOOS != "windows" {
		os.Chmod(sock, 0o600)
	}
	h := NewHost()
	logx.Printf("panes: pane host v%d (pid %d) listening on %s", HostVersion, os.Getpid(), sock)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	go func() {
		s := <-sig
		logx.Printf("panes: %v: shutting down", s)
		l.Close()
	}()
	err = Serve(l, h)
	n := h.WindowCount()
	h.Close()
	l.Close()
	os.Remove(sock)
	if err != nil && !errors.Is(err, net.ErrClosed) {
		logx.Printf("panes: serve: %v", err)
		return 1
	}
	logx.Printf("panes: pane host exiting (%d windows closed)", n)
	return 0
}
