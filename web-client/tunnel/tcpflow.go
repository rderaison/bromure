package main

import (
	"crypto/rand"
	"encoding/binary"
	"io"
	"sync"
)

// One TCP connection from a local process, terminated here and spliced to an
// upstream stream (a `forward <ip> <port>` channel through the app). A port of
// the macOS fat client's TCPFlow.swift, for a lossless point-to-point TUN:
// 3-way handshake, data both ways within the peer's window, FIN/RST teardown,
// duplicates re-ACKed; no retransmission timers (the TUN doesn't drop).
//
// Client → upstream: in-order bytes are accepted up to the advertised window
// and queued in `pending`; the writer goroutine drains them to the upstream.
// The window advertised is what's left of 64 KiB once pending is counted, so
// in-window data is never refused and the window never shrinks below what was
// sent under it. Upstream → client: the reader goroutine sends segments of at
// most `mss`, waiting while the client's window is full.

const maxWindow = 65535

// upstream is the stream a flow is spliced to (a *net.UnixConn in production).
type upstream interface {
	io.ReadWriteCloser
	CloseWrite() error
}

type flowKey struct {
	srcIP   uint32
	srcPort uint16
	dstIP   uint32
	dstPort uint16
}

func keyOf(s tcpSegment) flowKey {
	return flowKey{srcIP: s.srcIP, srcPort: s.srcPort, dstIP: s.dstIP, dstPort: s.dstPort}
}

type flowState int

const (
	stConnecting flowState = iota
	stSynReceived
	stEstablished
	stClosing
	stClosed
)

type tcpFlow struct {
	key      flowKey
	mss      int
	dial     func() (upstream, error)
	send     func(tcpSegment)
	onClosed func(flowKey)

	mu              sync.Mutex
	cond            *sync.Cond // on mu: window room, pending bytes, state changes
	state           flowState
	sndNxt, sndUna  uint32
	rcvNxt          uint32
	clientWindow    uint32
	up              upstream
	finSent         bool
	clientFin       bool
	pending         []byte
	shutdownPending bool
	lastWindow      int
}

func newTCPFlow(key flowKey, clientISN uint32, mss int, dial func() (upstream, error),
	send func(tcpSegment), onClosed func(flowKey)) *tcpFlow {
	var b [4]byte
	_, _ = rand.Read(b[:])
	isn := binary.BigEndian.Uint32(b[:])
	f := &tcpFlow{
		key: key, mss: mss, dial: dial, send: send, onClosed: onClosed,
		sndNxt: isn, sndUna: isn, rcvNxt: clientISN + 1, // SYN consumes one seq
		clientWindow: 65535, lastWindow: maxWindow,
	}
	f.cond = sync.NewCond(&f.mu)
	return f
}

// start dials the upstream off the packet loop; on success it answers the SYN,
// on failure it resets. The client retransmits its SYN meanwhile.
func (f *tcpFlow) start() {
	go func() {
		up, err := f.dial()
		f.mu.Lock()
		defer f.mu.Unlock()
		if f.state != stConnecting {
			if up != nil {
				up.Close()
			}
			return
		}
		if err != nil || up == nil {
			f.sendRSTLocked()
			f.closeLocked()
			return
		}
		f.up = up
		f.state = stSynReceived
		f.emitSynAckLocked()
		f.sndNxt++ // our SYN consumes a seq
		go f.writer(up)
	}()
}

func (f *tcpFlow) emitSynAckLocked() {
	f.send(tcpSegment{
		srcIP: f.key.dstIP, dstIP: f.key.srcIP, srcPort: f.key.dstPort, dstPort: f.key.srcPort,
		seq: f.sndUna, ack: f.rcvNxt, flags: flagSYN | flagACK, window: f.advertisedWindowLocked(),
		mss: uint16(f.mss),
	})
}

// onInbound handles a segment from the local kernel. Payload bytes are copied.
func (f *tcpFlow) onInbound(seg tcpSegment) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.state == stClosed {
		return
	}
	if seg.flags&flagRST != 0 {
		f.closeLocked()
		return
	}
	// A retransmitted SYN (ours was slow, or lost): answer it again.
	if seg.flags&flagSYN != 0 && seg.flags&flagACK == 0 {
		if f.state == stSynReceived {
			f.emitSynAckLocked()
		}
		return
	}

	if seg.flags&flagACK != 0 {
		if seqLE(f.sndUna, seg.ack) && seqLE(seg.ack, f.sndNxt) {
			f.sndUna = seg.ack
		}
		f.clientWindow = uint32(seg.window)
		f.cond.Broadcast()
		if f.state == stSynReceived && seg.ack == f.sndNxt {
			f.state = stEstablished
			go f.reader(f.up)
		}
		f.closeIfFullyClosedLocked() // may be the ACK of our FIN
	}

	// A bare segment from before what we expect (a zero-window probe) is
	// answered with the window as it is now.
	if len(seg.payload) == 0 && seg.flags&(flagSYN|flagFIN|flagRST) == 0 && seqLT(seg.seq, f.rcvNxt) {
		f.emitLocked(flagACK, nil)
	}

	// Data: in order only (gaps are dropped, the client retransmits;
	// duplicates are re-ACKed). None before our SYN-ACK went out.
	if len(seg.payload) > 0 && f.state != stConnecting && f.state != stClosed {
		if seg.seq == f.rcvNxt {
			accept := len(seg.payload)
			if room := maxWindow - len(f.pending); accept > room {
				accept = max(room, 0)
			}
			f.rcvNxt += uint32(accept)
			f.pending = append(f.pending, seg.payload[:accept]...)
			if accept > 0 {
				f.cond.Broadcast() // the writer
			}
			f.emitLocked(flagACK, nil)
		} else if seqLT(seg.seq, f.rcvNxt) {
			f.emitLocked(flagACK, nil)
		}
	}

	// FIN (maybe on the last data segment: matched including that payload).
	if seg.flags&flagFIN != 0 && f.state != stConnecting && f.state != stClosed &&
		seg.seq+uint32(len(seg.payload)) == f.rcvNxt && !f.clientFin {
		f.rcvNxt++
		f.clientFin = true
		f.emitLocked(flagACK, nil)
		// Half-close toward the upstream once what's pending went out.
		if len(f.pending) == 0 {
			if f.up != nil {
				_ = f.up.CloseWrite()
			}
		} else {
			f.shutdownPending = true
		}
		f.closeIfFullyClosedLocked()
	}
}

// writer drains pending to the upstream (blocking writes, off the lock).
func (f *tcpFlow) writer(up upstream) {
	for {
		f.mu.Lock()
		for len(f.pending) == 0 && f.state != stClosed {
			f.cond.Wait()
		}
		if f.state == stClosed {
			f.mu.Unlock()
			return
		}
		chunk := append([]byte(nil), f.pending...)
		f.mu.Unlock()

		n, err := up.Write(chunk)

		f.mu.Lock()
		if f.state == stClosed {
			f.mu.Unlock()
			return
		}
		f.pending = f.pending[n:]
		if len(f.pending) == 0 {
			f.pending = nil
		}
		if err != nil {
			// The upstream is gone: nothing more will reach it.
			f.sendRSTLocked()
			f.closeLocked()
			f.mu.Unlock()
			return
		}
		f.announceWindowLocked()
		if len(f.pending) == 0 && f.shutdownPending {
			f.shutdownPending = false
			_ = up.CloseWrite()
		}
		f.closeIfFullyClosedLocked()
		f.mu.Unlock()
	}
}

// announceWindowLocked sends a window update once the window has grown by two
// segments, or back to half, so the client resumes without waiting on its
// persist timer.
func (f *tcpFlow) announceWindowLocked() {
	now := maxWindow - len(f.pending)
	if now-f.lastWindow >= 2*f.mss || (f.lastWindow < maxWindow/2 && now >= maxWindow/2) {
		f.emitLocked(flagACK, nil)
	}
}

// reader sends what the upstream says to the client, within its window.
func (f *tcpFlow) reader(up upstream) {
	buf := make([]byte, f.mss)
	for {
		n, err := up.Read(buf)
		if n > 0 && !f.sendData(buf[:n]) {
			return
		}
		if err != nil {
			f.remoteClosed()
			return
		}
	}
}

// sendData sends b as segments, waiting for room in the client's window.
// False once the flow is closed.
func (f *tcpFlow) sendData(b []byte) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	for off := 0; off < len(b); {
		for f.state == stEstablished && f.inFlight() >= f.clientWindow {
			f.cond.Wait()
		}
		if f.state != stEstablished {
			return false
		}
		room := int(f.clientWindow) - int(f.inFlight())
		n := min(len(b)-off, f.mss, max(room, 1))
		f.emitLocked(flagPSH|flagACK, b[off:off+n])
		f.sndNxt += uint32(n)
		off += n
	}
	return true
}

// remoteClosed: the upstream ended (EOF or error) — our FIN.
func (f *tcpFlow) remoteClosed() {
	f.mu.Lock()
	defer f.mu.Unlock()
	if (f.state != stEstablished && f.state != stSynReceived) || f.finSent {
		return
	}
	f.emitLocked(flagFIN|flagACK, nil)
	f.sndNxt++
	f.finSent = true
	f.state = stClosing
	f.closeIfFullyClosedLocked()
}

// closeIfFullyClosedLocked: both sides FINed, ours ACKed, nothing pending.
// Waiting for the FIN's ACK keeps the client's last ACK from hitting a
// removed flow (and drawing a RST).
func (f *tcpFlow) closeIfFullyClosedLocked() {
	if f.finSent && f.clientFin && f.sndUna == f.sndNxt && len(f.pending) == 0 && !f.shutdownPending {
		f.closeLocked()
	}
}

func (f *tcpFlow) close() {
	f.mu.Lock()
	f.closeLocked()
	f.mu.Unlock()
}

func (f *tcpFlow) closeLocked() {
	if f.state == stClosed {
		return
	}
	f.state = stClosed
	if f.up != nil {
		f.up.Close() // unblocks the reader and the writer
	}
	f.pending = nil
	f.cond.Broadcast()
	f.onClosed(f.key)
}

func (f *tcpFlow) inFlight() uint32 { return f.sndNxt - f.sndUna }

func (f *tcpFlow) emitLocked(flags uint8, payload []byte) {
	f.send(tcpSegment{
		srcIP: f.key.dstIP, dstIP: f.key.srcIP, srcPort: f.key.dstPort, dstPort: f.key.srcPort,
		seq: f.sndNxt, ack: f.rcvNxt, flags: flags, window: f.advertisedWindowLocked(), payload: payload,
	})
}

func (f *tcpFlow) advertisedWindowLocked() uint16 {
	f.lastWindow = max(0, maxWindow-len(f.pending))
	return uint16(f.lastWindow)
}

func (f *tcpFlow) sendRSTLocked() {
	f.send(tcpSegment{
		srcIP: f.key.dstIP, dstIP: f.key.srcIP, srcPort: f.key.dstPort, dstPort: f.key.srcPort,
		seq: f.sndNxt, ack: f.rcvNxt, flags: flagRST | flagACK,
	})
}

// Modular sequence comparisons (RFC 793).
func seqLT(a, b uint32) bool { return int32(a-b) < 0 }
func seqLE(a, b uint32) bool { return int32(a-b) <= 0 }
