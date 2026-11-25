package main

import (
	"io"
	"log"
	"sync"
)

// The userspace stack behind the TUN — a port of the macOS fat client's
// UtunForwarder.swift + UtunUDP.swift. It reads the raw IPv4 packets the
// kernel routes to the TUN (only the remote's workspace subnet is routed
// there) and:
//   - TCP: terminates each flow (tcpflow.go) and splices it to a
//     `forward <ip> <port>` stream;
//   - UDP: all datagrams to one guest share a `forward-udp <ip>` stream,
//     length-prefixed frames carrying each flow's return info;
//   - ICMP echo: answered locally (`ping` shows the tunnel is up).
// Streams are opened through the app (appdial.go), which carries them over its
// SSH connection with the device's key.

const tunMSS = tunMTU - 40 // IPv4 + TCP headers

type forwarder struct {
	tun     io.ReadWriter
	network uint32
	mask    uint32
	dialTCP func(ip string, port int) (upstream, error)
	dialUDP func(ip string) (upstream, error)

	wmu   sync.Mutex // serializes TUN writes
	fmu   sync.Mutex
	flows map[flowKey]*tcpFlow
	umu   sync.Mutex
	udp   map[uint32]*udpChannel
	frags *reassembler // used by the packet loop only
}

func newForwarder(tun io.ReadWriter, network, mask uint32,
	dialTCP func(string, int) (upstream, error), dialUDP func(string) (upstream, error)) *forwarder {
	return &forwarder{tun: tun, network: network, mask: mask, dialTCP: dialTCP, dialUDP: dialUDP,
		flows: map[flowKey]*tcpFlow{}, udp: map[uint32]*udpChannel{}, frags: newReassembler()}
}

// run reads packets until the TUN fails; it returns that error.
func (fw *forwarder) run() error {
	buf := make([]byte, 65536)
	for {
		n, err := fw.tun.Read(buf)
		if err != nil {
			return err
		}
		fw.handlePacket(buf[:n])
	}
}

// handlePacket handles one packet; p is only used during the call.
func (fw *forwarder) handlePacket(p []byte) {
	if len(p) < 20 || p[0]>>4 != 4 {
		return // not IPv4 (IPv6 is off on the TUN anyway)
	}
	if u32(p, 16)&fw.mask != fw.network {
		return // only traffic into the routed subnet
	}
	// A datagram bigger than the TUN's MTU arrives in fragments: only the
	// whole one holds the UDP (or ICMP) message.
	if p = fw.frags.add(p); p == nil {
		return
	}
	switch p[9] {
	case protoTCP:
		if seg, ok := parseTCP(p); ok {
			fw.handleTCP(seg)
		}
	case protoUDP:
		if d, ok := parseUDP(p); ok {
			fw.udpChannel(d.dstIP).send(d.srcIP, d.srcPort, d.dstPort, d.payload)
		}
	case protoICMP:
		if r := icmpEchoReply(p); r != nil {
			fw.write(r)
		}
	}
}

// write sends a packet to the kernel, in fragments if it's bigger than the
// TUN's MTU (a large UDP reply or echo reply).
func (fw *forwarder) write(pkt []byte) {
	fw.wmu.Lock()
	defer fw.wmu.Unlock()
	for _, f := range fragmentIPv4(pkt, tunMTU) {
		if _, err := fw.tun.Write(f); err != nil {
			log.Printf("tun write: %v", err)
			return
		}
	}
}

func (fw *forwarder) writeSegment(s tcpSegment) { fw.write(buildTCP(s)) }

func (fw *forwarder) handleTCP(seg tcpSegment) {
	key := keyOf(seg)
	fw.fmu.Lock()
	flow := fw.flows[key]
	if flow == nil && seg.flags&flagSYN != 0 && seg.flags&(flagACK|flagRST) == 0 {
		ip, port := ipString(seg.dstIP), int(seg.dstPort)
		flow = newTCPFlow(key, seg.seq, tunMSS,
			func() (upstream, error) { return fw.dialTCP(ip, port) },
			fw.writeSegment,
			func(k flowKey) { fw.fmu.Lock(); delete(fw.flows, k); fw.fmu.Unlock() })
		fw.flows[key] = flow
		fw.fmu.Unlock()
		flow.start()
		return
	}
	fw.fmu.Unlock()
	if flow == nil {
		// A stray segment for no flow: a RST so the local kernel gives up.
		if seg.flags&flagRST == 0 {
			ack := seg.seq + uint32(len(seg.payload))
			if seg.flags&(flagSYN|flagFIN) != 0 {
				ack++
			}
			fw.writeSegment(tcpSegment{srcIP: seg.dstIP, dstIP: seg.srcIP, srcPort: seg.dstPort, dstPort: seg.srcPort,
				seq: seg.ack, ack: ack, flags: flagRST | flagACK})
		}
		return
	}
	flow.onInbound(seg)
}

func (fw *forwarder) flowCount() int {
	fw.fmu.Lock()
	defer fw.fmu.Unlock()
	return len(fw.flows)
}

// ── UDP ──────────────────────────────────────────────────────────────────

func (fw *forwarder) udpChannel(guest uint32) *udpChannel {
	fw.umu.Lock()
	defer fw.umu.Unlock()
	if c := fw.udp[guest]; c != nil {
		return c
	}
	c := &udpChannel{guest: guest, fw: fw}
	fw.udp[guest] = c
	return c
}

func (fw *forwarder) dropUDP(c *udpChannel) {
	fw.umu.Lock()
	if fw.udp[c.guest] == c {
		delete(fw.udp, c.guest)
	}
	fw.umu.Unlock()
}

// udpChannel carries every datagram to one guest over one stream:
//
//	frame = [u16 bodyLen][u32 srcIP][u16 srcPort][u16 dstPort][payload]
//
// The remote relay keeps a socket per (srcIP, srcPort, dstPort) and frames the
// replies back the same way (srcIP/srcPort: the local process's).
type udpChannel struct {
	guest uint32
	fw    *forwarder

	mu         sync.Mutex
	up         upstream
	connecting bool
	closed     bool
	queued     [][]byte
	wmu        sync.Mutex // serializes frame writes
}

const maxQueuedUDP = 256

func (c *udpChannel) send(srcIP uint32, srcPort, dstPort uint16, payload []byte) {
	if len(payload) > 65535-8 {
		return
	}
	f := udpFrame(srcIP, srcPort, dstPort, payload)
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return
	}
	if up := c.up; up != nil {
		c.mu.Unlock()
		c.writeFrame(up, f)
		return
	}
	if len(c.queued) < maxQueuedUDP { // UDP may drop; never grow without bound
		c.queued = append(c.queued, f)
	}
	dial := !c.connecting
	c.connecting = true
	c.mu.Unlock()
	if dial {
		go c.dial()
	}
}

func (c *udpChannel) writeFrame(up upstream, f []byte) {
	c.wmu.Lock()
	_, _ = up.Write(f)
	c.wmu.Unlock()
}

func (c *udpChannel) dial() {
	up, err := c.fw.dialUDP(ipString(c.guest))
	c.mu.Lock()
	if err != nil || c.closed {
		c.closed = true
		c.mu.Unlock()
		if up != nil {
			up.Close()
		}
		c.fw.dropUDP(c) // a later datagram dials again
		return
	}
	c.up = up
	q := c.queued
	c.queued = nil
	c.mu.Unlock()
	for _, f := range q {
		c.writeFrame(up, f)
	}
	c.readLoop(up)
}

// readLoop turns reply frames back into UDP packets for the TUN.
func (c *udpChannel) readLoop(up upstream) {
	var acc []byte
	buf := make([]byte, 65536)
	for {
		n, err := up.Read(buf)
		acc = append(acc, buf[:n]...)
		for len(acc) >= 2 {
			bodyLen := int(u16(acc, 0))
			if len(acc) < 2+bodyLen {
				break
			}
			body := acc[2 : 2+bodyLen]
			if bodyLen >= 8 {
				// guest → process: src = (guest, dstPort), dst = (process, srcPort).
				c.fw.write(buildUDP(udpDatagram{srcIP: c.guest, dstIP: u32(body, 0),
					srcPort: u16(body, 6), dstPort: u16(body, 4), payload: body[8:]}))
			}
			acc = acc[2+bodyLen:]
		}
		if len(acc) == 0 {
			acc = nil
		}
		if err != nil {
			break
		}
	}
	c.mu.Lock()
	c.closed = true
	c.mu.Unlock()
	up.Close()
	c.fw.dropUDP(c)
}

func udpFrame(srcIP uint32, srcPort, dstPort uint16, payload []byte) []byte {
	bodyLen := 8 + len(payload)
	f := make([]byte, 2+bodyLen)
	putU16(f, 0, uint16(bodyLen))
	putU32(f, 2, srcIP)
	putU16(f, 6, srcPort)
	putU16(f, 8, dstPort)
	copy(f[10:], payload)
	return f
}
