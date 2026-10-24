package sshserver

import (
	"fmt"
	"os"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/rderaison/bromure/sidecar/internal/panes"
)

// The remote menu: what a plain SSH login (a shell, or any other command)
// gets. The macOS Sidecar puts it straight into the agents' tmux; here a
// small TUI lists the pane host's windows, and attaches to the one picked
// as a pane host client at the SSH pty's size. Ctrl-B d detaches (back to
// the list), Ctrl-B Ctrl-B sends a Ctrl-B.

const (
	detachPrefix = 0x02 // Ctrl-B
	esc          = "\x1b"
	// What a window may have left on: the alt screen, a hidden cursor,
	// bracketed paste, mouse reporting, colours.
	resetModes = esc + "[?1049l" + esc + "[?25h" + esc + "[?2004l" + esc + "[?1000l" + esc + "[?1002l" +
		esc + "[?1003l" + esc + "[?1006l" + esc + "[0m"
)

func (ss *session) startMenu(req *ssh.Request) {
	if !ss.started.CompareAndSwap(false, true) {
		return
	}
	reply(req, true)
	go func() {
		code := ss.runMenu()
		ss.exit(code)
	}()
}

// menuInput reads the channel into chunks; closed at the client's EOF.
// It stops once done is closed (the menu ended).
func (ss *session) menuInput(done <-chan struct{}) <-chan []byte {
	in := make(chan []byte, 16)
	go func() {
		defer close(in)
		buf := make([]byte, 4096)
		for {
			n, err := ss.ch.Read(buf)
			if n > 0 {
				select {
				case in <- append([]byte(nil), buf[:n]...):
				case <-done:
					return
				}
			}
			if err != nil {
				return
			}
		}
	}()
	return in
}

func (ss *session) write(s string) { _, _ = ss.ch.Write([]byte(s)) }

func (ss *session) runMenu() int {
	if ss.srv.cfg.Panes == nil {
		ss.write("Bromure Sidecar: no agent windows here.\r\n")
		return 1
	}
	client, err := ss.srv.cfg.Panes()
	if err != nil {
		ss.write("Bromure Sidecar: the pane host isn't running (" + sanitize(err.Error()) + ").\r\n")
		return 1
	}
	defer client.Close()
	done := make(chan struct{})
	defer close(done)
	in := ss.menuInput(done)
	host, _ := os.Hostname()
	selected := 0
	var note string
	for {
		wins, err := client.List(false)
		if err != nil {
			ss.write(resetModes + esc + "[2J" + esc + "[H" + "Bromure Sidecar: " + sanitize(err.Error()) + "\r\n")
			return 1
		}
		if selected >= len(wins) {
			selected = len(wins) - 1
		}
		if selected < 0 {
			selected = 0
		}
		ss.write(renderMenu(host, wins, selected, note))
		note = ""

		var chunk []byte
		var ok bool
		select {
		case chunk, ok = <-in:
			if !ok {
				return 0
			}
		case <-time.After(2 * time.Second):
			continue // refresh the list
		}
		attach := -1
		for _, k := range keys(chunk) {
			switch {
			case k == "q" || k == "\x03" || k == "\x04":
				ss.write(resetModes + esc + "[2J" + esc + "[H")
				return 0
			case k == esc+"[A" || k == esc+"OA" || k == "k":
				if selected > 0 {
					selected--
				}
			case k == esc+"[B" || k == esc+"OB" || k == "j":
				if selected < len(wins)-1 {
					selected++
				}
			case k == "\r" || k == "\n":
				if selected < len(wins) {
					attach = wins[selected].Index
				}
			case len(k) == 1 && k[0] >= '0' && k[0] <= '9':
				for i, w := range wins {
					if fmt.Sprint(w.Index) == k {
						selected = i
					}
				}
			}
		}
		if attach < 0 {
			continue
		}
		msg, clientGone := ss.attach(client, attach, in)
		ss.write(resetModes + esc + "[2J" + esc + "[H")
		if clientGone {
			return 0
		}
		note = msg
	}
}

// keys splits input into keys (escape sequences whole).
func keys(b []byte) []string {
	var out []string
	for i := 0; i < len(b); i++ {
		if b[i] == 0x1b && i+2 < len(b) && (b[i+1] == '[' || b[i+1] == 'O') {
			out = append(out, string(b[i:i+3]))
			i += 2
			continue
		}
		out = append(out, string(b[i:i+1]))
	}
	return out
}

func renderMenu(host string, wins []panes.Window, selected int, note string) string {
	var b strings.Builder
	b.WriteString(resetModes + esc + "[2J" + esc + "[H")
	b.WriteString(esc + "[1mBromure Sidecar" + esc + "[0m")
	if host != "" {
		b.WriteString(" — " + sanitize(host))
	}
	b.WriteString("\r\n\r\n")
	if len(wins) == 0 {
		b.WriteString("  No agent windows yet. Start a session from Bromure AC.\r\n")
	}
	for i, w := range wins {
		mark := "  "
		if i == selected {
			mark = esc + "[7m>" + " "
		}
		state := ""
		if !w.Alive {
			state = " (exited)"
		}
		clients := ""
		if w.Clients > 0 {
			clients = fmt.Sprintf("  [%d attached]", w.Clients)
		}
		name := w.Name
		if t := w.Options["@display"]; t != "" {
			name = t
		}
		fmt.Fprintf(&b, "%s%3d  %-24s %s%s%s%s\r\n", mark, w.Index, clip(sanitize(name), 24),
			clip(sanitize(w.Cwd), 60), state, clients, esc+"[0m")
	}
	b.WriteString("\r\n  ↑/↓ choose · Enter attach · q quit · Ctrl-B d detaches\r\n")
	if note != "" {
		b.WriteString("\r\n  " + sanitize(note) + "\r\n")
	}
	return b.String()
}

func clip(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n-1]) + "…"
}

// sanitize drops control characters (a window name is the agent's).
func sanitize(s string) string {
	return strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0) {
			return -1
		}
		return r
	}, s)
}

// attach runs one window until it exits or the user detaches. clientGone:
// the SSH client hung up.
func (ss *session) attach(client panes.Client, index int, in <-chan []byte) (note string, clientGone bool) {
	ss.mu.Lock()
	cols, rows := ss.cols, ss.rows
	ss.mu.Unlock()
	att, err := client.Attach(index, cols, rows, false)
	if err != nil {
		return "Couldn't attach: " + err.Error(), false
	}
	ss.mu.Lock()
	ss.att = att
	ss.mu.Unlock()
	defer func() {
		ss.mu.Lock()
		ss.att = nil
		ss.mu.Unlock()
		_ = att.Close()
	}()
	// The size may have changed between the read and the attach.
	ss.mu.Lock()
	c2, r2 := ss.cols, ss.rows
	ss.mu.Unlock()
	if c2 != cols || r2 != rows {
		_ = att.Resize(c2, r2)
	}
	outDone := make(chan struct{})
	go func() {
		defer close(outDone)
		buf := make([]byte, 32<<10)
		for {
			n, err := att.Read(buf)
			if n > 0 {
				if _, werr := ss.ch.Write(buf[:n]); werr != nil {
					return
				}
			}
			if err != nil {
				return
			}
		}
	}()
	prefix := false
	for {
		select {
		case <-outDone:
			return fmt.Sprintf("Window %d exited.", index), false
		case <-att.Exited():
			<-outDone
			return fmt.Sprintf("Window %d exited (%d).", index, att.ExitCode()), false
		case chunk, ok := <-in:
			if !ok {
				return "", true
			}
			var send []byte
			for _, c := range chunk {
				if prefix {
					prefix = false
					switch c {
					case 'd':
						if len(send) > 0 {
							_, _ = att.Write(send)
						}
						return "Detached.", false
					case detachPrefix:
						send = append(send, detachPrefix)
					default:
						send = append(send, detachPrefix, c)
					}
					continue
				}
				if c == detachPrefix {
					prefix = true
					continue
				}
				send = append(send, c)
			}
			if len(send) > 0 {
				if _, err := att.Write(send); err != nil {
					return "Window closed.", false
				}
			}
		}
	}
}
