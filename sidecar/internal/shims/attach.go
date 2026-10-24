package shims

import (
	"fmt"
	"io"
	"os"
	"time"

	"golang.org/x/term"

	"github.com/rderaison/bromure/sidecar/internal/panes"
)

// attach is `tmux attach` / `new-session` without -d for a terminal that
// reaches this machine over SSH (`vm attach`): the caller's terminal shows
// one window through a pane-host attachment. The prefix is C-b: d
// detaches, n / p / 0-9 switch windows, C-b C-b sends a C-b. The app's own
// views don't come through here (the frame stream serves them).
func (r *tmuxRun) attach(idx int, readOnly bool) int {
	if r.c == nil {
		r.printErr(r.noServer())
		return 1
	}
	in, _ := r.stdin.(*os.File)
	out, _ := r.stdout.(*os.File)
	if in != nil && term.IsTerminal(int(in.Fd())) {
		if st, err := term.MakeRaw(int(in.Fd())); err == nil {
			defer term.Restore(int(in.Fd()), st)
		}
	} else if r.stdin == nil {
		fmt.Fprintln(r.stderr, "open terminal failed: not a terminal")
		return 1
	}
	size := func() (int, int) {
		if out != nil {
			if w, h, err := term.GetSize(int(out.Fd())); err == nil && w > 0 && h > 0 {
				return w, h
			}
		}
		return 80, 24
	}

	input := make(chan []byte, 16)
	go func() {
		buf := make([]byte, 4096)
		for {
			n, err := r.stdin.Read(buf)
			if n > 0 {
				input <- append([]byte(nil), buf[:n]...)
			}
			if err != nil {
				close(input)
				return
			}
		}
	}()

	for {
		cols, rows := size()
		att, err := r.c.Attach(idx, cols, rows, false)
		if err != nil {
			r.printErr(errf("can't find window: %d", idx))
			return 1
		}
		outDone := make(chan struct{})
		go func() {
			io.Copy(r.stdout, att)
			close(outDone)
		}()
		next, code := r.attachLoop(att, idx, readOnly, input, size, cols, rows, outDone)
		att.Close()
		if next < 0 {
			return code
		}
		idx = next
	}
}

// attachLoop runs one attachment: it returns the next window to show, or
// -1 and the exit status.
func (r *tmuxRun) attachLoop(att panes.Attachment, idx int, readOnly bool, input chan []byte,
	size func() (int, int), cols, rows int, outDone chan struct{}) (int, int) {
	tick := time.NewTicker(500 * time.Millisecond)
	defer tick.Stop()
	prefix := false
	for {
		select {
		case <-att.Exited():
			fmt.Fprint(r.stdout, "\r\n[exited]\r\n")
			return -1, 0
		case <-outDone:
			fmt.Fprint(r.stdout, "\r\n[lost server]\r\n")
			return -1, 1
		case <-tick.C:
			if c, rw := size(); c != cols || rw != rows {
				cols, rows = c, rw
				_ = att.Resize(cols, rows)
			}
		case b, ok := <-input:
			if !ok {
				return -1, 0
			}
			var pass []byte
			for _, ch := range b {
				if prefix {
					prefix = false
					switch {
					case ch == 'd':
						if len(pass) > 0 && !readOnly {
							att.Write(pass)
						}
						fmt.Fprint(r.stdout, "\r\n[detached (from session "+panes.SessionName+")]\r\n")
						return -1, 0
					case ch == 'n' || ch == 'p' || (ch >= '0' && ch <= '9'):
						if to, ok := r.switchTarget(idx, ch); ok {
							if len(pass) > 0 && !readOnly {
								att.Write(pass)
							}
							return to, 0
						}
						continue
					case ch == 0x02:
						pass = append(pass, 0x02)
						continue
					default:
						pass = append(pass, 0x02, ch)
						continue
					}
				}
				if ch == 0x02 {
					prefix = true
					continue
				}
				pass = append(pass, ch)
			}
			if len(pass) > 0 && !readOnly {
				att.Write(pass)
			}
		}
	}
}

func (r *tmuxRun) switchTarget(idx int, ch byte) (int, bool) {
	r.invalidate()
	ws, err := r.visible()
	if err != nil || len(ws) == 0 {
		return 0, false
	}
	if ch >= '0' && ch <= '9' {
		for _, w := range ws {
			if w.Index == int(ch-'0') {
				_ = r.c.SelectWindow(w.Index)
				return w.Index, true
			}
		}
		return 0, false
	}
	pos := 0
	for k, w := range ws {
		if w.Index == idx {
			pos = k
		}
	}
	if ch == 'n' {
		pos = (pos + 1) % len(ws)
	} else {
		pos = (pos - 1 + len(ws)) % len(ws)
	}
	_ = r.c.SelectWindow(ws[pos].Index)
	return ws[pos].Index, true
}
