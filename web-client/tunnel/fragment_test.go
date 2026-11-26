package main

import (
	"bytes"
	"io"
	"net"
	"testing"
	"time"
)

func payloadOf(n int) []byte {
	b := make([]byte, n)
	for i := range b {
		b[i] = byte(i*7 + i>>8)
	}
	return b
}

// bigUDP is a UDP packet that doesn't fit the TUN's MTU, with an IP id.
func bigUDP(n int, id uint16) []byte {
	p := buildUDP(udpDatagram{srcIP: ip("10.0.0.2"), dstIP: ip("192.168.64.5"), srcPort: 40000, dstPort: 53, payload: payloadOf(n)})
	putU16(p, 4, id)
	putU16(p, 6, 0) // the kernel fragments what's sent without DF
	p[10], p[11] = 0, 0
	putU16(p, 10, checksum(p[:20], 0))
	return p
}

func TestFragmentIPv4(t *testing.T) {
	p := bigUDP(4000, 9)
	frags := fragmentIPv4(p, tunMTU)
	if len(frags) != 3 {
		t.Fatalf("%d fragments", len(frags))
	}
	got := 0
	for i, f := range frags {
		if len(f) > tunMTU || checksum(f[:20], 0) != 0 || u16(f, 4) != 9 {
			t.Fatalf("fragment %d: len %d", i, len(f))
		}
		fl := u16(f, 6)
		if fl&0x4000 != 0 || (fl&0x2000 != 0) != (i < 2) || int(fl&0x1fff)*8 != got {
			t.Fatalf("fragment %d flags %#x", i, fl)
		}
		got += len(f) - 20
	}
	if got != len(p)-20 {
		t.Fatalf("fragments carry %d bytes, want %d", got, len(p)-20)
	}
	if small := buildUDP(udpDatagram{srcIP: 1, dstIP: 2, payload: []byte("x")}); len(fragmentIPv4(small, tunMTU)) != 1 {
		t.Fatal("a packet that fits was split")
	}
}

func TestReassembler(t *testing.T) {
	now := time.Unix(1000, 0)
	r := newReassembler()
	r.now = func() time.Time { return now }
	p := bigUDP(3000, 1)
	f := fragmentIPv4(p, tunMTU)

	// Out of order, with a duplicate: whole and identical once complete.
	if r.add(f[2]) != nil || r.add(f[0]) != nil || r.add(f[0]) != nil {
		t.Fatal("completed early")
	}
	out := r.add(f[1])
	if out == nil || !bytes.Equal(out[20:], p[20:]) || u16(out, 2) != uint16(len(p)) || checksum(out[:20], 0) != 0 {
		t.Fatal("reassembly")
	}
	if _, ok := parseUDP(out); !ok {
		t.Fatal("reassembled datagram doesn't parse")
	}
	if len(r.pending) != 0 || r.mem != 0 {
		t.Fatalf("left behind: %d, %d bytes", len(r.pending), r.mem)
	}
	// A packet that isn't a fragment passes through.
	small := buildUDP(udpDatagram{srcIP: 1, dstIP: 2, payload: []byte("x")})
	if !bytes.Equal(r.add(small), small) {
		t.Fatal("non-fragment")
	}
	// Overlapping fragments drop the datagram.
	g := fragmentIPv4(bigUDP(3000, 2), tunMTU)
	r.add(g[0])
	ov := append([]byte(nil), g[1]...)
	putU16(ov, 6, 0x2000|uint16((1480-8)/8))
	ov[10], ov[11] = 0, 0
	putU16(ov, 10, checksum(ov[:20], 0))
	r.add(ov)
	if len(r.pending) != 0 || r.add(g[1]) != nil || r.add(g[2]) != nil {
		t.Fatal("overlap not dropped")
	}
	r.pending = map[fragKey]*reassembly{}
	r.mem = 0
	// Incomplete datagrams expire.
	h := fragmentIPv4(bigUDP(3000, 3), tunMTU)
	r.add(h[0])
	now = now.Add(reassemblyTimeout + time.Second)
	r.add(fragmentIPv4(bigUDP(3000, 4), tunMTU)[0])
	if r.add(h[1]) != nil || r.add(h[2]) != nil {
		t.Fatal("expired fragments completed")
	}
	// At most maxReassemblies in progress: the oldest goes.
	r = newReassembler()
	for i := 0; i < maxReassemblies+5; i++ {
		r.add(fragmentIPv4(bigUDP(3000, uint16(100+i)), tunMTU)[0])
	}
	if len(r.pending) != maxReassemblies {
		t.Fatalf("%d in progress", len(r.pending))
	}
	// A middle fragment whose length isn't a multiple of 8 is refused.
	bad := append([]byte(nil), fragmentIPv4(bigUDP(3000, 7), tunMTU)[0][:1499]...)
	putU16(bad, 2, 1499)
	if r.add(bad) != nil {
		t.Fatal("odd middle fragment accepted")
	}
}

// The finding: a UDP datagram bigger than the MTU reaches the remote whole,
// and a reply bigger than the MTU comes back as valid fragments.
func TestForwarderLargeUDP(t *testing.T) {
	tun := newFakeTun()
	var remote net.Conn
	ready := make(chan struct{})
	fw := newForwarder(tun, ip("192.168.64.0"), 0xffffff00, nil, func(string) (upstream, error) {
		a, b, _ := unixPair()
		remote = b
		close(ready)
		return pipeUp{a}, nil
	})
	go fw.run()
	f := fragmentIPv4(bigUDP(3000, 42), tunMTU)
	for i := len(f) - 1; i >= 0; i-- {
		tun.in <- f[i]
	}
	select {
	case <-ready:
	case <-time.After(3 * time.Second):
		t.Fatal("the fragmented datagram never reached the remote")
	}
	frame := make([]byte, 2+8+3000)
	if _, err := io.ReadFull(remote, frame); err != nil {
		t.Fatal(err)
	}
	if u16(frame, 0) != 8+3000 || !bytes.Equal(frame[10:], payloadOf(3000)) {
		t.Fatal("the datagram didn't reach the remote whole")
	}
	// A 4000-byte reply: fragments the kernel can reassemble.
	remote.Write(udpFrame(ip("10.0.0.2"), 40000, 53, payloadOf(4000)))
	r := newReassembler()
	var whole []byte
	for whole == nil {
		select {
		case <-tun.got:
		case <-time.After(3 * time.Second):
			t.Fatal("no reply")
		}
		tun.mu.Lock()
		pkt := tun.out[0]
		tun.out = tun.out[1:]
		tun.mu.Unlock()
		if len(pkt) > tunMTU || checksum(pkt[:20], 0) != 0 {
			t.Fatalf("reply fragment of %d bytes", len(pkt))
		}
		whole = r.add(pkt)
	}
	d, ok := parseUDP(whole)
	if !ok || d.srcIP != ip("192.168.64.5") || d.dstPort != 40000 || !bytes.Equal(d.payload, payloadOf(4000)) ||
		checksum(whole[20:], pseudoHeader(d.srcIP, d.dstIP, protoUDP, len(whole)-20)) != 0 {
		t.Fatal("bad reply")
	}
}

// The same pattern for ICMP: a ping bigger than the MTU is answered.
func TestForwarderLargePing(t *testing.T) {
	tun := newFakeTun()
	fw := newForwarder(tun, ip("192.168.64.0"), 0xffffff00, nil, nil)
	go fw.run()
	n := 3000
	req := make([]byte, 20+8+n)
	req[0] = 0x45
	putU16(req, 2, uint16(len(req)))
	putU16(req, 4, 77)
	req[8], req[9] = 64, protoICMP
	putU32(req, 12, ip("10.0.0.2"))
	putU32(req, 16, ip("192.168.64.5"))
	req[20] = 8
	copy(req[28:], payloadOf(n))
	putU16(req, 22, checksum(req[20:], 0))
	putU16(req, 10, checksum(req[:20], 0))
	for _, f := range fragmentIPv4(req, tunMTU) {
		tun.in <- f
	}
	r := newReassembler()
	var whole []byte
	for whole == nil {
		select {
		case <-tun.got:
		case <-time.After(3 * time.Second):
			t.Fatal("no echo reply")
		}
		tun.mu.Lock()
		pkt := tun.out[0]
		tun.out = tun.out[1:]
		tun.mu.Unlock()
		whole = r.add(pkt)
	}
	if whole[20] != 0 || !bytes.Equal(whole[28:], payloadOf(n)) || checksum(whole[20:], 0) != 0 {
		t.Fatal("bad echo reply")
	}
}
