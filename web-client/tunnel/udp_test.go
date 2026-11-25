package main

import (
	"io"
	"net"
	"sync"
	"testing"
	"time"
)

// A UDP relay's reply frames name the local destination: only replies to a
// flow the local side started may reach the TUN (CWE-20).
func TestUDPRepliesOnlyToLocalFlows(t *testing.T) {
	tun := newFakeTun()
	var remote net.Conn
	ready := make(chan struct{})
	fw := newForwarder(tun, ip("192.168.64.0"), 0xffffff00, nil, func(string) (upstream, error) {
		a, b, _ := unixPair()
		remote = b
		close(ready)
		return pipeUp{a}, nil
	})
	var mu sync.Mutex
	now := time.Unix(1000, 0)
	fw.now = func() time.Time { mu.Lock(); defer mu.Unlock(); return now }
	go fw.run()

	client := ip("10.0.0.2")
	tun.in <- buildUDP(udpDatagram{srcIP: client, dstIP: ip("192.168.64.5"), srcPort: 40000, dstPort: 53, payload: []byte("q")})
	select {
	case <-ready:
	case <-time.After(3 * time.Second):
		t.Fatal("no channel")
	}
	io.ReadFull(remote, make([]byte, 11)) // the request frame

	next := func() (udpDatagram, bool) {
		select {
		case <-tun.got:
		case <-time.After(500 * time.Millisecond):
			return udpDatagram{}, false
		}
		tun.mu.Lock()
		p := tun.out[0]
		tun.out = tun.out[1:]
		tun.mu.Unlock()
		d, _ := parseUDP(p)
		return d, true
	}
	// Forged: another local address, another local port, a guest port nothing
	// was sent to. Then the genuine reply. Frames are handled in order, so
	// the first packet on the TUN must be the genuine one.
	remote.Write(udpFrame(ip("10.0.0.9"), 40000, 53, []byte("other address")))
	remote.Write(udpFrame(client, 22, 53, []byte("other local port")))
	remote.Write(udpFrame(client, 40000, 54, []byte("other guest port")))
	remote.Write(udpFrame(client, 40000, 53, []byte("answer")))
	d, ok := next()
	if !ok || string(d.payload) != "answer" || d.dstIP != client || d.dstPort != 40000 || d.srcPort != 53 {
		t.Fatalf("first packet on the TUN: %+v %v", d, ok)
	}
	if d, ok := next(); ok {
		t.Fatalf("a forged reply got through: %+v", d)
	}

	// Past the timeout with nothing sent: replies for the flow stop.
	mu.Lock()
	now = now.Add(udpFlowTimeout + time.Second)
	mu.Unlock()
	remote.Write(udpFrame(client, 40000, 53, []byte("late")))
	if d, ok := next(); ok {
		t.Fatalf("a reply to an expired flow got through: %+v", d)
	}
	// A new datagram from the local side opens it again.
	tun.in <- buildUDP(udpDatagram{srcIP: client, dstIP: ip("192.168.64.5"), srcPort: 40000, dstPort: 53, payload: []byte("q2")})
	io.ReadFull(remote, make([]byte, 12))
	remote.Write(udpFrame(client, 40000, 53, []byte("again")))
	if d, ok := next(); !ok || string(d.payload) != "again" {
		t.Fatalf("reply after a new request: %+v %v", d, ok)
	}
}

func TestUDPFlowTableBounded(t *testing.T) {
	fw := newForwarder(newFakeTun(), 0, 0, nil, nil)
	c := &udpChannel{guest: 1, fw: fw, sent: map[udpTuple]time.Time{}}
	for i := 0; i < maxUDPFlows+100; i++ {
		c.noteSent(udpTuple{srcIP: 2, srcPort: uint16(i), dstPort: 53})
	}
	if len(c.sent) != maxUDPFlows {
		t.Fatalf("%d flows kept", len(c.sent))
	}
	if !c.replyAllowed(udpTuple{srcIP: 2, srcPort: uint16(maxUDPFlows + 99), dstPort: 53}) {
		t.Fatal("the newest flow was evicted")
	}
}
