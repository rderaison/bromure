package delegation

import (
	"bufio"
	"bytes"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/paths"
)

// PaneWindow resolves a TMUX_PANE value ("%3") to its window index, for a
// shim started without BROMURE_WINDOW (Codex's shim path on the Mac). Set by
// the caller before RunShim; nil = not resolvable.
var PaneWindow func(pane string) (int, error)

// HelloWindow is what the shim announces after "bromure-hello ":
// "w<index>" from BROMURE_WINDOW (Windows), else TMUX_PANE through
// PaneWindow, else "w-1".
func HelloWindow() string {
	if v := strings.TrimSpace(os.Getenv("BROMURE_WINDOW")); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return "w" + strconv.Itoa(n)
		}
	}
	if pane := os.Getenv("TMUX_PANE"); pane != "" && PaneWindow != nil {
		if n, err := PaneWindow(pane); err == nil {
			return "w" + strconv.Itoa(n)
		}
	}
	return "w-1"
}

// RunShim is `bromure-sidecar __mcp-delegation`: the stdio MCP server an
// agent runs. It pipes stdio to delegation.sock, announcing its window
// first, and reconnects (announcing again) whenever the socket drops: the
// stream moves between the local fallback and a Bromure AC's relay that
// way, without the agent noticing.
func RunShim() int {
	logx.Quiet() // stdout is the MCP stream; keep stderr clean too
	return runShim(shimOptions{
		stdin:  os.Stdin,
		stdout: os.Stdout,
		socket: paths.DelegationSocket(),
		hello:  HelloWindow(),
	})
}

type shimOptions struct {
	stdin    io.Reader
	stdout   io.Writer
	socket   string
	hello    string
	watchdog time.Duration // default 2 s
	pause    time.Duration // between streams, default 200 ms
	now      func() time.Time
}

func runShim(o shimOptions) int {
	if o.watchdog == 0 {
		o.watchdog = 2 * time.Second
	}
	if o.pause == 0 {
		o.pause = 200 * time.Millisecond
	}
	if o.now == nil {
		o.now = time.Now
	}
	connectHub := func() net.Conn {
		delay := 200 * time.Millisecond
		for {
			c, err := net.Dial("unix", o.socket)
			if err == nil {
				if _, err := writeAll(c, []byte("bromure-hello "+o.hello+"\n")); err == nil {
					return c
				}
				_ = c.Close()
			}
			time.Sleep(delay)
			delay *= 2
			if delay > 5*time.Second {
				delay = 5 * time.Second
			}
		}
	}

	// In-flight calls with the stream they went out on: see shimStream.
	stream := newShimStream(nil)

	var outMu sync.Mutex
	emit := func(line []byte) {
		outMu.Lock()
		_, _ = o.stdout.Write(line)
		outMu.Unlock()
	}

	// stdin → hub, one line at a time (a line never splits across two
	// connections).
	go func() {
		r := bufio.NewReaderSize(o.stdin, 64<<10)
		for {
			line, err := r.ReadBytes('\n')
			if len(line) > 0 {
				for {
					c, gen, _ := stream.current(0)
					// stale: a newer stream took over, write there; failed:
					// this one is shut down, the reader reconnects.
					res := stream.send(line, c, gen)
					if res == sendSent || res == sendOwnedByReader {
						break
					}
				}
			}
			if err != nil {
				break
			}
		}
		stream.inputClosed()
	}()

	// A relay that falls silent (no EOF: a half-dead link) holds its calls
	// for ever: past a call's deadline, the stream counts as lost.
	stopWatch := make(chan struct{})
	defer close(stopWatch)
	go func() {
		t := time.NewTicker(o.watchdog)
		defer t.Stop()
		for {
			select {
			case <-stopWatch:
				return
			case <-t.C:
			}
			orphans, late := stream.watchdog(o.now())
			for _, c := range orphans {
				emit(lostReply(c))
			}
			if late != nil {
				logx.Printf("delegation: no reply to %s within %d s — dropping the relay stream", late.label, int(late.limit/time.Second))
			}
		}
	}()

	// hub → stdout, a line at a time.
	buf := make([]byte, 64<<10)
	var carry []shimCall // held by a local stream: to send again
	for {
		c := connectHub()
		gen := stream.open(c)
		if len(carry) > 0 {
			logx.Printf("delegation: %d held call(s) go to the relay", len(carry))
			for len(carry) > 0 {
				res := stream.send(carry[0].line, c, gen)
				if res != sendSent && res != sendOwnedByReader {
					break // this stream's gone too: its end follows
				}
				carry = carry[1:]
			}
		}
		var partial []byte
		for {
			n, err := c.Read(buf)
			if n > 0 {
				partial = append(partial, buf[:n]...)
				for {
					nl := bytes.IndexByte(partial, '\n')
					if nl < 0 {
						break
					}
					line := append([]byte(nil), partial[:nl+1]...)
					partial = partial[nl+1:]
					if strings.TrimSpace(string(line)) == LocalMarker {
						stream.markLocal(gen)
						continue
					}
					stream.answered(line)
					emit(line)
				}
			}
			if err != nil {
				break
			}
		}
		wasLocal, held, open := stream.ended(c, gen)
		if wasLocal {
			carry = append(carry, held...) // never done: again, over the next stream
		} else {
			for _, h := range held {
				emit(lostReply(h))
			}
			if len(held) > 0 {
				logx.Printf("delegation: relay stream lost with %d call(s) under way", len(held))
			}
		}
		if !open {
			return 0
		}
		time.Sleep(o.pause)
	}
}
