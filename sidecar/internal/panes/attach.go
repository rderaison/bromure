package panes

import (
	"errors"
	"fmt"
	"io"
	"os"
	"sync"

	xterm "golang.org/x/term"
)

// detachKey is the prefix (C-b, like tmux); prefix then 'd' detaches,
// prefix twice sends one.
const detachKey = 0x02

// terminalReset undoes what the program may have left on the terminal.
const terminalReset = "\x1b[?1049l\x1b[?2004l\x1b[?1l\x1b>\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?1004l\x1b[r\x1b[0m\x1b[?25h"

// RunAttach is `bromure-sidecar attach <index>`: this terminal becomes a
// client of the window until C-b d or the program exits.
func RunAttach(index int, passive bool) int {
	c, err := Connect()
	if err != nil {
		fmt.Fprintln(os.Stderr, "no pane host running:", err)
		return 1
	}
	defer c.Close()
	inFd, outFd := int(os.Stdin.Fd()), int(os.Stdout.Fd())
	if !xterm.IsTerminal(inFd) || !xterm.IsTerminal(outFd) {
		fmt.Fprintln(os.Stderr, "open terminal failed: not a terminal")
		return 1
	}
	cols, rows, err := xterm.GetSize(outFd)
	if err != nil {
		cols, rows = 80, 24
	}
	att, err := c.Attach(index, cols, rows, passive)
	if err != nil {
		if errors.Is(err, ErrNoWindow) {
			fmt.Fprintf(os.Stderr, "can't find window: %d\n", index)
		} else {
			fmt.Fprintln(os.Stderr, err)
		}
		return 1
	}
	restore, err := setupConsole(inFd, outFd)
	if err != nil {
		att.Close()
		fmt.Fprintln(os.Stderr, "terminal:", err)
		return 1
	}

	var once sync.Once
	done := make(chan string, 1)
	finish := func(why string) { once.Do(func() { done <- why }) }

	go func() {
		io.Copy(os.Stdout, att)
		finish("exited")
	}()
	stopSize := watchSize(outFd, func(c, r int) { att.Resize(c, r) })
	go func() {
		buf := make([]byte, 4096)
		prefix := false
		for {
			n, err := os.Stdin.Read(buf)
			if n > 0 {
				var out []byte
				for _, b := range buf[:n] {
					switch {
					case prefix:
						prefix = false
						switch b {
						case 'd':
							if len(out) > 0 {
								att.Write(out)
							}
							finish("detached")
							return
						case detachKey:
							out = append(out, detachKey)
						default:
							out = append(out, detachKey, b)
						}
					case b == detachKey:
						prefix = true
					default:
						out = append(out, b)
					}
				}
				if len(out) > 0 {
					if _, err := att.Write(out); err != nil {
						finish("exited")
						return
					}
				}
			}
			if err != nil {
				finish("detached")
				return
			}
		}
	}()

	why := <-done
	stopSize()
	att.Close()
	os.Stdout.WriteString(terminalReset)
	restore()
	if why == "detached" {
		fmt.Fprintf(os.Stdout, "\r\n[detached (from session %s)]\r\n", SessionName)
	} else {
		fmt.Fprintf(os.Stdout, "\r\n[exited]\r\n")
	}
	return 0
}
