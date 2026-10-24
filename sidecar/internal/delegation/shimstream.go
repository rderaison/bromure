package delegation

import (
	"net"
	"sync"
	"time"
)

// sendResult is what a write came to. stale: the stream isn't the current
// one any more (nothing written; write again on the current one). failed:
// the write didn't go through; the stream is shut down and the call taken
// back, to be written again. ownedByReader: the stream ended first and the
// reader holds the call.
type sendResult int

const (
	sendSent sendResult = iota
	sendStale
	sendFailed
	sendOwnedByReader
)

// shimStream is DelegationShimStream: the shim's one stream to the hub,
// and who may end it. Only the reader opens a stream (open) and closes one
// (ended). A writer whose write failed, and the watchdog, only shut down
// the stream they saw, and only while it's still the current one (conn AND
// generation), so the reader sees its end and settles every call it held.
type shimStream struct {
	mu      sync.Mutex
	cond    *sync.Cond
	writeMu sync.Mutex // one writer at a time; never closed mid-write by ended

	sock       net.Conn // nil between streams
	generation int
	readerGen  int // the generation the reader is on, until its ended (0: none)
	pending    shimCalls
	local      map[int]bool
	inputOpen  bool
	writeLine  func([]byte, net.Conn) bool
}

func newShimStream(writeLine func([]byte, net.Conn) bool) *shimStream {
	s := &shimStream{local: map[int]bool{}, inputOpen: true, writeLine: writeLine}
	if s.writeLine == nil {
		s.writeLine = func(b []byte, c net.Conn) bool { _, err := writeAll(c, b); return err == nil }
	}
	s.cond = sync.NewCond(&s.mu)
	return s
}

// open: the reader connected; c is the current stream now. Its generation.
func (s *shimStream) open(c net.Conn) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sock = c
	s.generation++
	s.readerGen = s.generation
	if !s.inputOpen {
		closeWrite(c)
	}
	s.cond.Broadcast()
	return s.generation
}

// markLocal: the hub said this stream is its local fallback.
func (s *shimStream) markLocal(gen int) {
	s.mu.Lock()
	s.local[gen] = true
	s.mu.Unlock()
}

func (s *shimStream) answered(line []byte) {
	s.mu.Lock()
	s.pending.answered(line)
	s.mu.Unlock()
}

// ended: the reader's stream ended. Closed here, once no write is under
// way, and every call it held handed back.
func (s *shimStream) ended(c net.Conn, gen int) (wasLocal bool, held []shimCall, inputOpen bool) {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	s.mu.Lock()
	if s.sock == c && s.generation == gen {
		s.sock = nil
	}
	if s.readerGen == gen {
		s.readerGen = 0
	}
	wasLocal = s.local[gen]
	delete(s.local, gen)
	held = s.pending.takeGen(gen)
	inputOpen = s.inputOpen
	s.mu.Unlock()
	_ = c.Close()
	return
}

// current is the current stream, waiting while the reader reconnects.
// timeout 0 waits for ever; past a timeout, ok is false.
func (s *shimStream) current(timeout time.Duration) (net.Conn, int, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.sock == nil && timeout > 0 {
		expired := false
		t := time.AfterFunc(timeout, func() {
			s.mu.Lock()
			expired = true
			s.cond.Broadcast()
			s.mu.Unlock()
		})
		defer t.Stop()
		for s.sock == nil {
			if expired {
				return nil, 0, false
			}
			s.cond.Wait()
		}
	}
	for s.sock == nil {
		s.cond.Wait()
	}
	return s.sock, s.generation, true
}

// send writes data on stream gen, recording it as in flight there.
func (s *shimStream) send(data []byte, c net.Conn, gen int) sendResult {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	s.mu.Lock()
	live := s.sock == c && s.generation == gen
	if live {
		s.pending.sent(data, gen, time.Now())
	}
	s.mu.Unlock()
	if !live {
		return sendStale
	}
	if s.writeLine(data, c) {
		return sendSent
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.abandonLocked(c, gen)
	key := requestKey(data)
	if key == "" {
		return sendFailed // not a call: just again
	}
	if s.pending.takeKey(key) != nil {
		return sendFailed
	}
	return sendOwnedByReader
}

// abandonLocked shuts stream (c, gen) down if it's still the current one:
// its reader's Read returns. (A Go conn is an object, not a reusable fd
// number: closing it can't hit a newer stream.)
func (s *shimStream) abandonLocked(c net.Conn, gen int) {
	if s.sock != c || s.generation != gen {
		return
	}
	_ = c.Close()
	s.sock = nil
}

// inputClosed: the agent closed stdin; no more calls, and the hub hears it.
func (s *shimStream) inputClosed() {
	s.mu.Lock()
	s.inputOpen = false
	if s.sock != nil {
		closeWrite(s.sock)
	}
	s.mu.Unlock()
}

// watchdog: calls past their deadline. On the stream the reader is on, that
// stream is shut down (the reader answers them at its end, after any reply
// it already read); on one the reader has left, answered here (orphans).
func (s *shimStream) watchdog(now time.Time) (orphans []shimCall, late *shimCall) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var overdue []shimCall
	for _, c := range s.pending.overdue(now) {
		if !s.local[c.gen] {
			overdue = append(overdue, c)
		}
	}
	for _, c := range overdue {
		if c.gen != s.readerGen {
			if t := s.pending.takeKey(c.key); t != nil {
				orphans = append(orphans, *t)
			}
		}
	}
	if s.sock != nil && s.generation == s.readerGen {
		for _, c := range overdue {
			if c.gen == s.readerGen {
				cc := c
				late = &cc
				break
			}
		}
	}
	if late != nil {
		s.abandonLocked(s.sock, s.generation)
	}
	return
}

// inFlight is what's in flight (tests).
func (s *shimStream) inFlight() []shimCall {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]shimCall(nil), s.pending.calls...)
}

func closeWrite(c net.Conn) {
	if cw, ok := c.(interface{ CloseWrite() error }); ok {
		_ = cw.CloseWrite()
	}
}
