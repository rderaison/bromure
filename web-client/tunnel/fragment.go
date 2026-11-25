package main

import "time"

// IPv4 fragmentation on the TUN. The TUN's MTU is 1500: a UDP datagram (or a
// ping) bigger than that reaches us as fragments, and only the reassembled
// datagram has a whole UDP/ICMP message in it; the other way, a reply bigger
// than the MTU has to go back to the kernel as fragments. (TCP never needs
// either: its segments are at most the MSS, and they're sent with DF.)

const (
	tunMTU = 1500

	// Reassembly bounds: a datagram is at most 64 KiB; at most this many are
	// in progress and this many bytes buffered across them (the oldest is
	// dropped to make room); one not complete in time is dropped (the
	// kernel's own ipfrag_time is 30 s).
	maxReassemblies   = 64
	maxReassemblyMem  = 4 << 20
	reassemblyTimeout = 30 * time.Second
)

type fragKey struct {
	src, dst uint32
	id       uint16
	proto    byte
}

type fragPiece struct {
	off  int // byte offset in the datagram's payload
	data []byte
}

type reassembly struct {
	started time.Time
	header  []byte // the first fragment's IP header (offset 0)
	pieces  []fragPiece
	total   int // payload length, once the last fragment (MF=0) is in; -1 before
	bytes   int
}

type reassembler struct {
	now     func() time.Time
	pending map[fragKey]*reassembly
	mem     int
}

func newReassembler() *reassembler {
	return &reassembler{now: time.Now, pending: map[fragKey]*reassembly{}}
}

// add takes one IPv4 packet (p is only read during the call). It returns the
// packet itself if it isn't a fragment, the whole datagram once a fragment
// completes one, and nil otherwise (more fragments to come, or dropped).
func (r *reassembler) add(p []byte) []byte {
	ihl, total, ok := ipv4Header(p)
	if !ok {
		return nil
	}
	flags := u16(p, 6)
	mf := flags&0x2000 != 0
	off := int(flags&0x1fff) * 8
	if !mf && off == 0 {
		return p // not a fragment
	}
	now := r.now()
	r.expire(now)

	data := p[ihl:total]
	// Every fragment but the last carries a multiple of 8 bytes; the whole
	// datagram fits in 64 KiB.
	if (mf && len(data)%8 != 0) || len(data) == 0 || ihl+off+len(data) > 65535 {
		return nil
	}
	key := fragKey{src: u32(p, 12), dst: u32(p, 16), id: u16(p, 4), proto: p[9]}
	a := r.pending[key]
	if a == nil {
		for len(r.pending) >= maxReassemblies || r.mem+len(data) > maxReassemblyMem {
			if !r.dropOldest() {
				return nil
			}
		}
		a = &reassembly{started: now, total: -1}
		r.pending[key] = a
	}
	end := off + len(data)
	for _, q := range a.pieces {
		if q.off == off && len(q.data) == len(data) {
			return nil // a duplicate
		}
		if off < q.off+len(q.data) && q.off < end {
			r.drop(key) // overlapping fragments: the datagram is dropped
			return nil
		}
	}
	if (a.total >= 0 && (end > a.total || !mf)) || (!mf && a.bytes > 0 && maxEnd(a) > end) {
		r.drop(key) // a second last fragment, or data past the end
		return nil
	}
	if r.mem+len(data) > maxReassemblyMem {
		r.drop(key)
		return nil
	}
	a.pieces = append(a.pieces, fragPiece{off: off, data: append([]byte(nil), data...)})
	a.bytes += len(data)
	r.mem += len(data)
	if off == 0 {
		a.header = append([]byte(nil), p[:ihl]...)
	}
	if !mf {
		a.total = end
	}
	if a.total < 0 || a.header == nil || a.bytes != a.total {
		return nil
	}
	// Complete (no overlaps, so the byte count proves the coverage).
	hl := len(a.header)
	out := make([]byte, hl+a.total)
	copy(out, a.header)
	for _, q := range a.pieces {
		copy(out[hl+q.off:], q.data)
	}
	putU16(out, 2, uint16(len(out)))
	putU16(out, 6, u16(out, 6)&0x4000) // keep DF, clear MF and the offset
	out[10], out[11] = 0, 0
	putU16(out, 10, checksum(out[:hl], 0))
	r.drop(key)
	return out
}

func maxEnd(a *reassembly) int {
	m := 0
	for _, q := range a.pieces {
		m = max(m, q.off+len(q.data))
	}
	return m
}

func (r *reassembler) drop(k fragKey) {
	if a := r.pending[k]; a != nil {
		r.mem -= a.bytes
		delete(r.pending, k)
	}
}

func (r *reassembler) dropOldest() bool {
	var oldest *fragKey
	var t time.Time
	for k, a := range r.pending {
		if oldest == nil || a.started.Before(t) {
			k := k
			oldest, t = &k, a.started
		}
	}
	if oldest == nil {
		return false
	}
	r.drop(*oldest)
	return true
}

func (r *reassembler) expire(now time.Time) {
	for k, a := range r.pending {
		if now.Sub(a.started) > reassemblyTimeout {
			r.drop(k)
		}
	}
}

// fragmentIPv4 splits an IPv4 packet bigger than mtu into fragments that fit
// (DF cleared: we're the sender). A packet that fits is returned as is.
func fragmentIPv4(p []byte, mtu int) [][]byte {
	ihl, total, ok := ipv4Header(p)
	if !ok || total <= mtu {
		return [][]byte{p[:max(total, 0)]}
	}
	step := (mtu - ihl) &^ 7
	data := p[ihl:total]
	baseOff := int(u16(p, 6)&0x1fff) * 8 // (0 for the packets we build)
	moreAfter := u16(p, 6)&0x2000 != 0
	var out [][]byte
	for o := 0; o < len(data); o += step {
		n := min(step, len(data)-o)
		f := make([]byte, ihl+n)
		copy(f, p[:ihl])
		copy(f[ihl:], data[o:o+n])
		putU16(f, 2, uint16(ihl+n))
		flags := uint16((baseOff + o) / 8)
		if o+n < len(data) || moreAfter {
			flags |= 0x2000
		}
		putU16(f, 6, flags)
		f[10], f[11] = 0, 0
		putU16(f, 10, checksum(f[:ihl], 0))
		out = append(out, f)
	}
	return out
}
