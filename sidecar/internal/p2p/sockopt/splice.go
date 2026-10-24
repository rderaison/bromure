package sockopt

import (
	"errors"
	"io"
	"net"
	"os"
	"sync"
	"time"
)

// Splice is FatForward.splice: a bidirectional pump, half-close aware (when
// one direction ends the other keeps draining). Writes toward a side in
// bounded get a StallWrite deadline; MaxWriteStalls in a row with no
// progress declare that peer dead and close both at once. Both are closed
// when it returns.
func Splice(a, b net.Conn, aBounded, bBounded bool) {
	TuneInteractive(a, false)
	TuneInteractive(b, false)
	var once sync.Once
	closeBoth := func() { once.Do(func() { a.Close(); b.Close() }) }
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); pump(b, a, bBounded, closeBoth) }()
	go func() { defer wg.Done(); pump(a, b, aBounded, closeBoth) }()
	wg.Wait()
	closeBoth()
}

type closeWriter interface{ CloseWrite() error }

// pump copies from → to.
func pump(to, from net.Conn, bounded bool, kill func()) {
	buf := make([]byte, 1<<16)
	for {
		n, rerr := from.Read(buf)
		if n > 0 {
			if !writeAll(to, buf[:n], bounded) {
				kill()
				return
			}
		}
		if rerr != nil {
			if cw, ok := to.(closeWriter); ok {
				_ = cw.CloseWrite()
			} else if rerr != io.EOF {
				kill()
			}
			return
		}
	}
}

func writeAll(to net.Conn, p []byte, bounded bool) bool {
	stalls := 0
	for len(p) > 0 {
		if bounded {
			_ = to.SetWriteDeadline(time.Now().Add(StallWrite))
		}
		n, err := to.Write(p)
		p = p[n:]
		if n > 0 {
			stalls = 0
		}
		if err == nil {
			continue
		}
		if bounded && errors.Is(err, os.ErrDeadlineExceeded) {
			if n == 0 {
				stalls++
			}
			if stalls >= MaxWriteStalls {
				return false
			}
			continue
		}
		return false
	}
	if bounded {
		_ = to.SetWriteDeadline(time.Time{})
	}
	return true
}
