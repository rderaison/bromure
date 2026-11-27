package main

// IPv4 / TCP / UDP / ICMP parsing and building for the userspace stack — a
// port of the macOS fat client's UtunPacket.swift. Pure byte math (testable
// without a TUN). Packets carry no link header (IFF_TUN|IFF_NO_PI). Multi-byte
// fields are network order; addresses are host-order uint32.

const (
	flagFIN = 0x01
	flagSYN = 0x02
	flagRST = 0x04
	flagPSH = 0x08
	flagACK = 0x10

	protoICMP = 1
	protoTCP  = 6
	protoUDP  = 17
)

type tcpSegment struct {
	srcIP, dstIP     uint32
	srcPort, dstPort uint16
	seq, ack         uint32
	flags            uint8
	window           uint16
	// mss, when non-zero, goes out as a TCP MSS option (on a SYN-ACK: the
	// local kernel otherwise assumes 536 bytes for what it sends us).
	mss     uint16
	payload []byte
}

type udpDatagram struct {
	srcIP, dstIP     uint32
	srcPort, dstPort uint16
	payload          []byte
}

func u16(p []byte, o int) uint16 { return uint16(p[o])<<8 | uint16(p[o+1]) }
func u32(p []byte, o int) uint32 {
	return uint32(p[o])<<24 | uint32(p[o+1])<<16 | uint32(p[o+2])<<8 | uint32(p[o+3])
}
func putU16(p []byte, o int, v uint16) { p[o] = byte(v >> 8); p[o+1] = byte(v) }
func putU32(p []byte, o int, v uint32) {
	p[o] = byte(v >> 24)
	p[o+1] = byte(v >> 16)
	p[o+2] = byte(v >> 8)
	p[o+3] = byte(v)
}

func ipString(v uint32) string {
	return itoa(int(v>>24&0xff)) + "." + itoa(int(v>>16&0xff)) + "." + itoa(int(v>>8&0xff)) + "." + itoa(int(v&0xff))
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	neg := n < 0
	if neg {
		n = -n
	}
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}

// ipv4Header returns the header length of a well-formed IPv4 packet whose
// total length fits in p, and that total length; ok false otherwise.
func ipv4Header(p []byte) (ihl, total int, ok bool) {
	if len(p) < 20 || p[0]>>4 != 4 {
		return 0, 0, false
	}
	ihl = int(p[0]&0x0f) * 4
	total = int(u16(p, 2))
	if ihl < 20 || total < ihl || total > len(p) {
		return 0, 0, false
	}
	return ihl, total, true
}

// parseTCP parses an IPv4/TCP packet; ok false if it isn't one. The payload
// aliases p.
func parseTCP(p []byte) (s tcpSegment, ok bool) {
	ihl, total, ok := ipv4Header(p)
	if !ok || p[9] != protoTCP || total < ihl+20 {
		return s, false
	}
	t := ihl
	dataOff := int(p[t+12]>>4) * 4
	if dataOff < 20 || ihl+dataOff > total {
		return s, false
	}
	return tcpSegment{
		srcIP: u32(p, 12), dstIP: u32(p, 16),
		srcPort: u16(p, t), dstPort: u16(p, t+2),
		seq: u32(p, t+4), ack: u32(p, t+8),
		flags: p[t+13], window: u16(p, t+14),
		payload: p[ihl+dataOff : total],
	}, true
}

// buildTCP builds an IPv4/TCP packet with both checksums.
func buildTCP(s tcpSegment) []byte {
	const ihl = 20
	tcpHdr := 20
	if s.mss != 0 {
		tcpHdr = 24
	}
	total := ihl + tcpHdr + len(s.payload)
	p := make([]byte, total)
	p[0] = 0x45
	putU16(p, 2, uint16(total))
	putU16(p, 6, 0x4000) // DF
	p[8] = 64
	p[9] = protoTCP
	putU32(p, 12, s.srcIP)
	putU32(p, 16, s.dstIP)
	putU16(p, 10, checksum(p[:ihl], 0))
	t := ihl
	putU16(p, t, s.srcPort)
	putU16(p, t+2, s.dstPort)
	putU32(p, t+4, s.seq)
	putU32(p, t+8, s.ack)
	p[t+12] = byte(tcpHdr/4) << 4
	p[t+13] = s.flags
	putU16(p, t+14, s.window)
	if s.mss != 0 {
		p[t+20], p[t+21] = 2, 4 // kind MSS, length 4
		putU16(p, t+22, s.mss)
	}
	copy(p[ihl+tcpHdr:], s.payload)
	putU16(p, t+16, checksum(p[ihl:], pseudoHeader(s.srcIP, s.dstIP, protoTCP, tcpHdr+len(s.payload))))
	return p
}

// parseUDP parses an IPv4/UDP packet; ok false if it isn't one.
func parseUDP(p []byte) (d udpDatagram, ok bool) {
	ihl, total, ok := ipv4Header(p)
	if !ok || p[9] != protoUDP || total < ihl+8 {
		return d, false
	}
	ulen := int(u16(p, ihl+4))
	if ulen < 8 || ihl+ulen > total {
		return d, false
	}
	return udpDatagram{
		srcIP: u32(p, 12), dstIP: u32(p, 16),
		srcPort: u16(p, ihl), dstPort: u16(p, ihl+2),
		payload: p[ihl+8 : ihl+ulen],
	}, true
}

// buildUDP builds an IPv4/UDP packet with both checksums.
func buildUDP(d udpDatagram) []byte {
	const ihl = 20
	udpLen := 8 + len(d.payload)
	p := make([]byte, ihl+udpLen)
	p[0] = 0x45
	putU16(p, 2, uint16(ihl+udpLen))
	putU16(p, 6, 0x4000)
	p[8] = 64
	p[9] = protoUDP
	putU32(p, 12, d.srcIP)
	putU32(p, 16, d.dstIP)
	putU16(p, 10, checksum(p[:ihl], 0))
	putU16(p, ihl, d.srcPort)
	putU16(p, ihl+2, d.dstPort)
	putU16(p, ihl+4, uint16(udpLen))
	copy(p[ihl+8:], d.payload)
	c := checksum(p[ihl:], pseudoHeader(d.srcIP, d.dstIP, protoUDP, udpLen))
	if c == 0 {
		c = 0xffff // 0 means "no checksum" in UDP
	}
	putU16(p, ihl+6, c)
	return p
}

// icmpEchoReply turns an ICMP echo request into its reply (nil if p isn't
// one). Answered by the tunnel itself, like the Mac's: `ping <guest>` shows
// the subnet is routed and the tunnel up; it doesn't reach the guest.
func icmpEchoReply(p []byte) []byte {
	ihl, total, ok := ipv4Header(p)
	if !ok || p[9] != protoICMP || total < ihl+8 || p[ihl] != 8 {
		return nil
	}
	r := make([]byte, total)
	copy(r, p[:total])
	copy(r[12:16], p[16:20]) // swap src/dst
	copy(r[16:20], p[12:16])
	r[8] = 64
	r[ihl] = 0 // echo reply
	r[ihl+2], r[ihl+3] = 0, 0
	putU16(r, ihl+2, checksum(r[ihl:total], 0))
	r[10], r[11] = 0, 0
	putU16(r, 10, checksum(r[:ihl], 0))
	return r
}

// pseudoHeader is the TCP/UDP pseudo-header's partial sum.
func pseudoHeader(src, dst uint32, proto byte, length int) uint32 {
	return src>>16 + src&0xffff + dst>>16 + dst&0xffff + uint32(proto) + uint32(length)
}

// checksum is the one's-complement 16-bit checksum of b, starting from sum.
func checksum(b []byte, sum uint32) uint16 {
	n := len(b)
	i := 0
	for ; i+1 < n; i += 2 {
		sum += uint32(b[i])<<8 | uint32(b[i+1])
	}
	if i < n {
		sum += uint32(b[i]) << 8
	}
	for sum>>16 != 0 {
		sum = sum&0xffff + sum>>16
	}
	return ^uint16(sum)
}

// parseCIDR parses "a.b.c.d/n" into network and mask; ok false otherwise.
func parseCIDR(s string) (network, mask uint32, ok bool) {
	slash := -1
	for i := 0; i < len(s); i++ {
		if s[i] == '/' {
			slash = i
		}
	}
	if slash < 0 {
		return 0, 0, false
	}
	ip, ok := parseIPv4(s[:slash])
	if !ok {
		return 0, 0, false
	}
	n, ok := atoi(s[slash+1:])
	if !ok || n < 0 || n > 32 {
		return 0, 0, false
	}
	if n > 0 {
		mask = ^uint32(0) << (32 - n)
	}
	return ip & mask, mask, true
}

// parseIPv4 parses a dotted quad strictly (no leading zeros).
func parseIPv4(s string) (uint32, bool) {
	var v uint32
	part, start := 0, 0
	for i := 0; i <= len(s); i++ {
		if i < len(s) && s[i] != '.' {
			continue
		}
		t := s[start:i]
		if len(t) == 0 || len(t) > 3 || (len(t) > 1 && t[0] == '0') {
			return 0, false
		}
		n, ok := atoi(t)
		if !ok || n > 255 {
			return 0, false
		}
		v = v<<8 | uint32(n)
		part++
		start = i + 1
	}
	return v, part == 4
}

func atoi(s string) (int, bool) {
	if len(s) == 0 || len(s) > 9 {
		return 0, false
	}
	n := 0
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
		n = n*10 + int(s[i]-'0')
	}
	return n, true
}
