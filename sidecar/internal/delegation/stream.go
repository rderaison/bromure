package delegation

import (
	"io"
	"sync"
)

// Stream is a duplex byte stream with a write-half close: an AF_UNIX
// connection, an SSH channel, a Watched wrapper of either.
type Stream interface {
	io.ReadWriteCloser
	CloseWrite() error
}

// Watched reads one chunk ahead of its consumer, so whether the far end
// has hung up (EOF waiting, nothing unread before it) can be answered at
// any time without consuming anything: what the Swift does with
// recv(MSG_PEEK|MSG_DONTWAIT) and poll(). That is portable here: AF_UNIX on
// Windows, and an SSH channel (no fd at all), behave the same. Reading
// ahead is bounded to one chunk, so backpressure is kept.
type Watched struct {
	rw    io.ReadWriteCloser
	mu    sync.Mutex
	cond  *sync.Cond
	chunk []byte
	buf   []byte // read ahead, not yet consumed (a slice of chunk)
	err   error  // the read error that ended the stream, once buf is drained
}

// Watch wraps rw; reading ahead starts at once.
func Watch(rw io.ReadWriteCloser) *Watched {
	w := &Watched{rw: rw, chunk: make([]byte, 32<<10)}
	w.cond = sync.NewCond(&w.mu)
	go w.readAhead()
	return w
}

func (w *Watched) readAhead() {
	for {
		w.mu.Lock()
		for len(w.buf) > 0 {
			w.cond.Wait()
		}
		w.mu.Unlock()
		n, err := w.rw.Read(w.chunk)
		w.mu.Lock()
		w.buf = w.chunk[:n]
		if err != nil {
			w.err = err
		}
		w.cond.Broadcast()
		w.mu.Unlock()
		if err != nil {
			return
		}
	}
}

// Read returns read-ahead bytes, then the error that ended the stream.
func (w *Watched) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	for len(w.buf) == 0 && w.err == nil {
		w.cond.Wait()
	}
	if len(w.buf) > 0 {
		n := copy(p, w.buf)
		w.buf = w.buf[n:]
		if len(w.buf) == 0 {
			w.cond.Broadcast()
		}
		return n, nil
	}
	return 0, w.err
}

func (w *Watched) Write(p []byte) (int, error) { return w.rw.Write(p) }

// Close closes the underlying stream (a blocked Read returns).
func (w *Watched) Close() error { return w.rw.Close() }

// CloseWrite half-closes the underlying stream when it can; otherwise it
// does nothing.
func (w *Watched) CloseWrite() error {
	if cw, ok := w.rw.(interface{ CloseWrite() error }); ok {
		return cw.CloseWrite()
	}
	return nil
}

// PeerClosed: the far end is done (EOF or an error waiting), and nothing
// unread is left before it. DelegationHub.peerClosed.
func (w *Watched) PeerClosed() bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	return len(w.buf) == 0 && w.err != nil
}

// IsOpen is the opposite: still connected, or data still to read.
// MachineLinker.isOpen.
func (w *Watched) IsOpen() bool { return !w.PeerClosed() }

// Underlying is the wrapped stream.
func (w *Watched) Underlying() io.ReadWriteCloser { return w.rw }

// Splice pumps a and b into each other until both directions end
// (MachineLinker.splice): at the end of one direction the receiving side's
// write half is closed, so EOF travels on. The caller closes both after.
func Splice(a, b io.ReadWriteCloser) {
	var wg sync.WaitGroup
	cp := func(from io.Reader, to io.Writer) {
		defer wg.Done()
		buf := make([]byte, 64<<10)
		for {
			n, err := from.Read(buf)
			if n > 0 {
				if _, werr := writeAll(to, buf[:n]); werr != nil {
					break
				}
			}
			if err != nil {
				break
			}
		}
		if cw, ok := to.(interface{ CloseWrite() error }); ok {
			_ = cw.CloseWrite()
		}
	}
	wg.Add(2)
	go cp(a, b)
	go cp(b, a)
	wg.Wait()
}

func writeAll(w io.Writer, p []byte) (int, error) {
	total := 0
	for len(p) > 0 {
		n, err := w.Write(p)
		total += n
		if err != nil {
			return total, err
		}
		if n == 0 {
			return total, io.ErrShortWrite
		}
		p = p[n:]
	}
	return total, nil
}
