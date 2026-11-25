package main

import (
	"bytes"
	"errors"
	"io"
	"net"
	"os"
	"sync"
	"testing"
	"time"
)

func ip(s string) uint32 { v, _ := parseIPv4(s); return v }

// A valid IPv4 header sums to 0; so does a TCP/UDP segment with its pseudo-header.
func checksumsOK(t *testing.T, p []byte) {
	t.Helper()
	ihl := int(p[0]&0x0f) * 4
	if checksum(p[:ihl], 0) != 0 {
		t.Fatalf("bad IP checksum")
	}
	total := int(u16(p, 2))
	switch p[9] {
	case protoTCP, protoUDP:
		if checksum(p[ihl:total], pseudoHeader(u32(p, 12), u32(p, 16), p[9], total-ihl)) != 0 {
			t.Fatalf("bad L4 checksum")
		}
	case protoICMP:
		if checksum(p[ihl:total], 0) != 0 {
			t.Fatalf("bad ICMP checksum")
		}
	}
}

func TestTCPRoundTrip(t *testing.T) {
	s := tcpSegment{srcIP: ip("192.168.64.5"), dstIP: ip("10.0.0.2"), srcPort: 3000, dstPort: 51000,
		seq: 0xfffffff0, ack: 42, flags: flagSYN | flagACK, window: 65535, mss: 1460, payload: []byte("hello, odd")}
	p := buildTCP(s)
	checksumsOK(t, p)
	g, ok := parseTCP(p)
	if !ok || g.srcIP != s.srcIP || g.dstPort != s.dstPort || g.seq != s.seq || g.flags != s.flags || string(g.payload) != "hello, odd" {
		t.Fatalf("round trip: %+v", g)
	}
	if p[20+12]>>4 != 6 || p[40] != 2 || u16(p, 42) != 1460 {
		t.Fatalf("MSS option missing")
	}
}

func TestUDPRoundTripAndICMP(t *testing.T) {
	d := udpDatagram{srcIP: ip("192.168.64.5"), dstIP: ip("10.1.2.3"), srcPort: 53, dstPort: 40000, payload: []byte{1, 2, 3}}
	p := buildUDP(d)
	checksumsOK(t, p)
	g, ok := parseUDP(p)
	if !ok || g.srcPort != 53 || !bytes.Equal(g.payload, []byte{1, 2, 3}) {
		t.Fatalf("udp: %+v", g)
	}
	// An echo request (type 8) becomes a reply with src/dst swapped.
	req := []byte{0x45, 0, 0, 28, 0, 1, 0, 0, 64, 1, 0, 0, 10, 0, 0, 2, 192, 168, 64, 5, 8, 0, 0, 0, 0, 7, 0, 1}
	putU16(req, 10, checksum(req[:20], 0))
	putU16(req, 22, checksum(req[20:], 0))
	r := icmpEchoReply(req)
	if r == nil || r[20] != 0 || u32(r, 12) != ip("192.168.64.5") || u32(r, 16) != ip("10.0.0.2") {
		t.Fatalf("icmp reply: %v", r)
	}
	checksumsOK(t, r)
	if icmpEchoReply(r) != nil {
		t.Fatalf("a reply isn't answered")
	}
}

func TestMalformed(t *testing.T) {
	for _, p := range [][]byte{nil, make([]byte, 19), {0x65, 0, 0, 20}, append([]byte{0x45, 0, 0xff, 0xff}, make([]byte, 36)...)} {
		if _, ok := parseTCP(p); ok {
			t.Fatalf("parsed %v", p)
		}
		if _, ok := parseUDP(p); ok {
			t.Fatalf("parsed %v", p)
		}
	}
}

func TestPrivateSlash24(t *testing.T) {
	good := map[string]string{"192.168.64.0/24": "192.168.64.0/24", "10.1.2.0/24": "10.1.2.0/24",
		"172.16.0.0/24": "172.16.0.0/24", "172.31.9.0/24": "172.31.9.0/24", "100.64.3.0/24": "100.64.3.0/24"}
	for in, want := range good {
		if got, ok := privateSlash24(in); !ok || got != want {
			t.Errorf("%s: %q %v", in, got, ok)
		}
	}
	for _, in := range []string{"192.168.64.1/24", "192.168.64.0/23", "192.168.064.0/24", "8.8.8.0/24",
		"172.32.0.0/24", "100.128.0.0/24", "192.168.64.0", "192.168.64.0/24 ", "1.2.3.4.5/24", "", "192.168.64.0/24;rm"} {
		if _, ok := privateSlash24(in); ok {
			t.Errorf("accepted %q", in)
		}
	}
}

func TestAdmit(t *testing.T) {
	routes := []route{{Dst: "default", Dev: "eth0"}, {Dst: "192.168.1.0/24", Dev: "eth0"},
		{Dst: "10.0.0.0/8", Dev: "wg0"}, {Dst: "192.168.64.255", Dev: "x", Type: "broadcast"}}
	if c, err := admit("SETUP 192.168.64.0/24", routes); err != nil || c != "192.168.64.0/24" {
		t.Fatalf("admit: %q %v", c, err)
	}
	for _, l := range []string{"SETUP 192.168.1.0/24", "SETUP 10.9.9.0/24"} {
		if _, err := admit(l, routes); err == nil {
			t.Errorf("%s: a covered subnet was admitted", l)
		}
	}
	for _, l := range []string{"HELLO", "SETUP 8.8.8.0/24", "SETUP 192.168.64.0/16"} {
		if _, err := admit(l, routes); err == nil {
			t.Errorf("%s admitted", l)
		}
	}
}

// ── a scripted TCP conversation through the forwarder ────────────────────

// fakeTun: the test writes packets "from the kernel"; the forwarder's
// writes are collected.
type fakeTun struct {
	in  chan []byte
	mu  sync.Mutex
	out [][]byte
	got chan struct{}
}

func newFakeTun() *fakeTun {
	return &fakeTun{in: make(chan []byte, 16), got: make(chan struct{}, 1024)}
}
func (f *fakeTun) Read(p []byte) (int, error) {
	b, ok := <-f.in
	if !ok {
		return 0, io.EOF
	}
	return copy(p, b), nil
}
func (f *fakeTun) Write(p []byte) (int, error) {
	f.mu.Lock()
	f.out = append(f.out, append([]byte(nil), p...))
	f.mu.Unlock()
	f.got <- struct{}{}
	return len(p), nil
}

// next waits for the forwarder's next TCP segment.
func (f *fakeTun) next(t *testing.T) tcpSegment {
	t.Helper()
	select {
	case <-f.got:
	case <-time.After(3 * time.Second):
		t.Fatal("no segment from the forwarder")
	}
	f.mu.Lock()
	p := f.out[0]
	f.out = f.out[1:]
	f.mu.Unlock()
	s, ok := parseTCP(p)
	if !ok {
		t.Fatalf("not TCP: %v", p)
	}
	return s
}

type pipeUp struct{ net.Conn }

func (p pipeUp) CloseWrite() error { return p.Conn.(*net.UnixConn).CloseWrite() }

func TestTCPFlowConversation(t *testing.T) {
	tun := newFakeTun()
	var remote net.Conn
	dialed := make(chan string, 1)
	dial := func(ipStr string, port int) (upstream, error) {
		a, b, err := unixPair()
		if err != nil {
			return nil, err
		}
		remote = b
		dialed <- ipStr + ":" + itoa(port)
		return pipeUp{a}, nil
	}
	fw := newForwarder(tun, ip("192.168.64.0"), 0xffffff00, dial, nil)
	go fw.run()

	client, guest := ip("10.0.0.2"), ip("192.168.64.5")
	seg := func(seq, ack uint32, flags uint8, payload string) []byte {
		return buildTCP(tcpSegment{srcIP: client, dstIP: guest, srcPort: 40000, dstPort: 3000,
			seq: seq, ack: ack, flags: flags, window: 65535, payload: []byte(payload)})
	}
	// Traffic outside the subnet is ignored.
	tun.in <- buildTCP(tcpSegment{srcIP: client, dstIP: ip("192.168.65.5"), srcPort: 1, dstPort: 2, flags: flagSYN})

	tun.in <- seg(1000, 0, flagSYN, "")
	if d := <-dialed; d != "192.168.64.5:3000" {
		t.Fatalf("dialed %s", d)
	}
	synack := tun.next(t)
	// (The MSS option itself is checked in TestTCPRoundTrip.)
	if synack.flags != flagSYN|flagACK || synack.ack != 1001 || synack.srcIP != guest || synack.dstIP != client {
		t.Fatalf("syn-ack: %+v", synack)
	}
	iss := synack.seq
	tun.in <- seg(1001, iss+1, flagACK, "")
	tun.in <- seg(1001, iss+1, flagACK|flagPSH, "GET / HTTP/1.0\r\n\r\n")
	ack := tun.next(t)
	if ack.ack != 1001+18 || ack.window < maxWindow-18 {
		t.Fatalf("data ack: %+v", ack)
	}
	got := make([]byte, 18)
	if _, err := io.ReadFull(remote, got); err != nil || string(got) != "GET / HTTP/1.0\r\n\r\n" {
		t.Fatalf("upstream got %q %v", got, err)
	}
	// A duplicate is re-ACKed, not delivered again.
	tun.in <- seg(1001, iss+1, flagACK|flagPSH, "GET / HTTP/1.0\r\n\r\n")
	if d := tun.next(t); d.ack != 1019 {
		t.Fatalf("dup ack: %+v", d)
	}
	// Upstream → client, then the upstream closes: data, then our FIN.
	remote.Write([]byte("HTTP/1.0 200 OK\r\n\r\nhi"))
	data := tun.next(t)
	if string(data.payload) != "HTTP/1.0 200 OK\r\n\r\nhi" || data.seq != iss+1 {
		t.Fatalf("data: %+v", data)
	}
	remote.(*net.UnixConn).CloseWrite()
	fin := tun.next(t)
	if fin.flags&flagFIN == 0 || fin.seq != iss+1+uint32(len(data.payload)) {
		t.Fatalf("fin: %+v", fin)
	}
	// The client ACKs everything and sends its FIN: the flow ends.
	tun.in <- seg(1019, fin.seq+1, flagACK|flagFIN, "")
	if last := tun.next(t); last.ack != 1020 {
		t.Fatalf("ack of client FIN: %+v", last)
	}
	if b, _ := io.ReadAll(remote); len(b) != 0 {
		t.Fatalf("upstream after half-close: %q", b)
	}
	waitFor(t, func() bool { return fw.flowCount() == 0 })
	// A segment for a flow that's gone draws a RST.
	tun.in <- seg(1020, fin.seq+1, flagACK, "")
	if r := tun.next(t); r.flags&flagRST == 0 {
		t.Fatalf("stray: %+v", r)
	}
}

func TestTCPFlowDialFailureResets(t *testing.T) {
	tun := newFakeTun()
	fw := newForwarder(tun, ip("192.168.64.0"), 0xffffff00,
		func(string, int) (upstream, error) { return nil, errors.New("refused") }, nil)
	go fw.run()
	tun.in <- buildTCP(tcpSegment{srcIP: ip("10.0.0.2"), dstIP: ip("192.168.64.9"), srcPort: 5, dstPort: 22, seq: 7, flags: flagSYN})
	if r := tun.next(t); r.flags&flagRST == 0 || r.ack != 8 {
		t.Fatalf("expected RST: %+v", r)
	}
	waitFor(t, func() bool { return fw.flowCount() == 0 })
}

func TestUDPFraming(t *testing.T) {
	tun := newFakeTun()
	var remote net.Conn
	ready := make(chan struct{})
	fw := newForwarder(tun, ip("192.168.64.0"), 0xffffff00, nil, func(ipStr string) (upstream, error) {
		if ipStr != "192.168.64.5" {
			t.Errorf("udp dialed %s", ipStr)
		}
		a, b, _ := unixPair()
		remote = b
		close(ready)
		return pipeUp{a}, nil
	})
	go fw.run()
	tun.in <- buildUDP(udpDatagram{srcIP: ip("10.0.0.2"), dstIP: ip("192.168.64.5"), srcPort: 40000, dstPort: 53, payload: []byte("q")})
	<-ready
	f := make([]byte, 11)
	if _, err := io.ReadFull(remote, f); err != nil {
		t.Fatal(err)
	}
	if u16(f, 0) != 9 || u32(f, 2) != ip("10.0.0.2") || u16(f, 6) != 40000 || u16(f, 8) != 53 || f[10] != 'q' {
		t.Fatalf("frame %v", f)
	}
	remote.Write(udpFrame(ip("10.0.0.2"), 40000, 53, []byte("answer")))
	select {
	case <-tun.got:
	case <-time.After(3 * time.Second):
		t.Fatal("no reply")
	}
	tun.mu.Lock()
	d, ok := parseUDP(tun.out[0])
	tun.mu.Unlock()
	if !ok || d.srcIP != ip("192.168.64.5") || d.srcPort != 53 || d.dstPort != 40000 || string(d.payload) != "answer" {
		t.Fatalf("reply %+v", d)
	}
}

func unixPair() (net.Conn, net.Conn, error) {
	dir := tmpDir()
	l, err := net.Listen("unix", dir+"/s")
	if err != nil {
		return nil, nil, err
	}
	defer l.Close()
	ch := make(chan net.Conn, 1)
	go func() { c, _ := l.Accept(); ch <- c }()
	a, err := net.Dial("unix", dir+"/s")
	if err != nil {
		return nil, nil, err
	}
	return a, <-ch, nil
}

var tmpN int
var tmpMu sync.Mutex

func tmpDir() string {
	tmpMu.Lock()
	defer tmpMu.Unlock()
	tmpN++
	d := "/tmp/bct-test-" + itoa(tmpN) + "-" + itoa(int(time.Now().UnixNano()%1e9))
	_ = mkdir(d)
	return d
}

func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	for i := 0; i < 300; i++ {
		if cond() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("condition not met")
}

func mkdir(d string) error { return os.MkdirAll(d, 0o700) }
