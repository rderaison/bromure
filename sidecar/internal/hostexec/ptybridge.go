package hostexec

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"sync"

	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/panes"
	"github.com/rderaison/bromure/sidecar/internal/paths"
)

// Frame types of the interactive exec stream: `[type u8][len u32be]
// [payload]` both ways — the framing bromure-agentd speaks over vsock.
const (
	FrameData   = 0
	FrameResize = 1 // cols u16be, rows u16be
	FrameExit   = 2 // i32be
	FrameEOF    = 3 // stdin closed
)

// Terminal is one end of a terminal the bridge pumps: a pane host
// attachment or a fresh pseudoconsole.
type Terminal interface {
	io.ReadWriteCloser
	Resize(cols, rows int) error
	// Wait blocks until the program exits; its exit code.
	Wait() int
}

// StartTerminal starts `command` (empty: an interactive login shell) in a
// fresh pseudoconsole under bash. Set by the daemon (internal/pty).
var StartTerminal func(command string, env []string, dir string, cols, rows int) (Terminal, error)

// ServeInteractive answers an `interactive: true` exec on conn: the HTTP
// header, then frames both ways until the program exits or the client goes.
// A body naming a `window` or `view` attaches to that pane host window as
// a client (`sizePassive` → passive) and runs nothing.
func ServeInteractive(conn net.Conn, body map[string]any, connect func() (panes.Client, error)) {
	defer conn.Close()
	cols := clampU16(intOf(body["cols"], 80))
	rows := clampU16(intOf(body["rows"], 24))
	var t Terminal
	var err error
	_, hasView := body["view"]
	_, hasWindow := body["window"]
	if hasView || hasWindow {
		t, err = attachWindow(body, cols, rows, connect)
	} else if StartTerminal == nil {
		err = fmt.Errorf("no terminal support")
	} else if FindShell() == nil {
		err = fmt.Errorf("%s", MissingShell)
	} else {
		command, _ := body["command"].(string)
		if command != "" {
			command = MapCommand(command)
		}
		env := CommandEnv()
		env = EnvSet(env, "TERM", "xterm-256color")
		env = EnvSet(env, "COLORTERM", "truecolor")
		t, err = StartTerminal(command, env, paths.Home(), cols, rows)
	}
	if err != nil {
		msg := fmt.Sprintf(`{"error":%q}`, "couldn't start a terminal: "+err.Error())
		fmt.Fprintf(conn, "HTTP/1.1 500 Error\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(msg), msg)
		return
	}
	defer t.Close()
	if _, err := io.WriteString(conn, "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n"); err != nil {
		return
	}
	var wmu sync.Mutex
	send := func(typ byte, payload []byte) error {
		wmu.Lock()
		defer wmu.Unlock()
		hdr := [5]byte{typ}
		binary.BigEndian.PutUint32(hdr[1:], uint32(len(payload)))
		if _, err := conn.Write(hdr[:]); err != nil {
			return err
		}
		_, err := conn.Write(payload)
		return err
	}
	clientGone := make(chan struct{})
	// Client → terminal.
	go func() {
		defer close(clientGone)
		var hdr [5]byte
		for {
			if _, err := io.ReadFull(conn, hdr[:]); err != nil {
				return
			}
			n := binary.BigEndian.Uint32(hdr[1:])
			if n > 1<<20 {
				return
			}
			payload := make([]byte, n)
			if _, err := io.ReadFull(conn, payload); err != nil {
				return
			}
			switch hdr[0] {
			case FrameData:
				if _, err := t.Write(payload); err != nil {
					return
				}
			case FrameResize:
				if n >= 4 {
					c := int(binary.BigEndian.Uint16(payload[0:2]))
					r := int(binary.BigEndian.Uint16(payload[2:4]))
					_ = t.Resize(c, r)
				}
			}
		}
	}()
	// Terminal → client, then the exit frame.
	outDone := make(chan struct{})
	go func() {
		defer close(outDone)
		buf := make([]byte, 32<<10)
		for {
			n, err := t.Read(buf)
			if n > 0 {
				if send(FrameData, buf[:n]) != nil {
					return
				}
			}
			if err != nil {
				return
			}
		}
	}()
	select {
	case <-outDone:
		code := t.Wait()
		var p [4]byte
		binary.BigEndian.PutUint32(p[:], uint32(int32(code)))
		_ = send(FrameExit, p[:])
		// Wakes the reader: its read on the socket sees the close.
		if cw, ok := conn.(interface{ CloseWrite() error }); ok {
			_ = cw.CloseWrite()
		}
	case <-clientGone:
		// The client went away: hang the terminal up.
	}
}

// attachWindow is a client terminal on a pane host window.
func attachWindow(body map[string]any, cols, rows int, connect func() (panes.Client, error)) (Terminal, error) {
	if connect == nil {
		return nil, fmt.Errorf("no pane host")
	}
	c, err := connect()
	if err != nil {
		return nil, err
	}
	idx := -1
	if n, ok := number(body["window"]); ok {
		idx = int(n)
	} else {
		ws, err := c.List(false)
		if err != nil {
			c.Close()
			return nil, err
		}
		for _, w := range ws {
			if w.Active {
				idx = w.Index
			}
		}
		if idx < 0 && len(ws) > 0 {
			idx = ws[0].Index
		}
		if idx < 0 {
			c.Close()
			return nil, fmt.Errorf("no window to attach to")
		}
	}
	passive, _ := body["sizePassive"].(bool)
	a, err := c.Attach(idx, cols, rows, passive)
	if err != nil {
		c.Close()
		return nil, err
	}
	logx.Printf("exec: terminal attached to window %d (passive=%v)", idx, passive)
	return &attachTerm{a: a, c: c}, nil
}

type attachTerm struct {
	a panes.Attachment
	c panes.Client
}

func (t *attachTerm) Read(p []byte) (int, error)  { return t.a.Read(p) }
func (t *attachTerm) Write(p []byte) (int, error) { return t.a.Write(p) }
func (t *attachTerm) Resize(c, r int) error       { return t.a.Resize(c, r) }
func (t *attachTerm) Close() error {
	err := t.a.Close()
	t.c.Close()
	return err
}
func (t *attachTerm) Wait() int {
	select {
	case <-t.a.Exited():
		return t.a.ExitCode()
	default:
		// Detached (the window lives on), like a tmux client detaching.
		return 0
	}
}

func clampU16(n int) int {
	if n < 1 {
		return 1
	}
	if n > 65535 {
		return 65535
	}
	return n
}
