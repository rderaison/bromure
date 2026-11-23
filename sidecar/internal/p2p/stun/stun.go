// Package stun is the minimal STUN wire codec the TURN-TCP relay path needs
// (RFC 5389, TURN attributes from RFC 5766/6062), ported message for message
// from Sources/AgentCoding/P2P/STUN.swift: Binding, Allocate, Refresh,
// CreatePermission, ConnectionBind / ConnectionAttempt, long-term-credential
// MESSAGE-INTEGRITY.
//
// Deliberately not a general STUN stack: like the Swift, requests carry no
// FINGERPRINT and responses' integrity isn't verified (the relay is
// untrusted by design; SSH end to end is the security boundary). The
// FINGERPRINT helpers exist for the fake relay in tests and for anyone who
// wants to check one; nothing on the wire path emits it.
package stun

import (
	"crypto/hmac"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha1"
	"encoding/binary"
	"hash/crc32"
	"net"
	"strconv"
)

// Message types (method | class, RFC 5389 §6 bit-interleave, precomputed).
const (
	BindingRequest              uint16 = 0x0001
	BindingSuccess              uint16 = 0x0101
	BindingError                uint16 = 0x0111
	AllocateRequest             uint16 = 0x0003
	AllocateSuccess             uint16 = 0x0103
	AllocateError               uint16 = 0x0113
	RefreshRequest              uint16 = 0x0004
	RefreshSuccess              uint16 = 0x0104
	RefreshError                uint16 = 0x0114
	CreatePermissionRequest     uint16 = 0x0008
	CreatePermissionSuccess     uint16 = 0x0108
	CreatePermissionError       uint16 = 0x0118
	ConnectRequest              uint16 = 0x000A // RFC 6062 §4.3 (client-initiated; the Swift never sends it)
	ConnectSuccess              uint16 = 0x010A
	ConnectionBindRequest       uint16 = 0x000B
	ConnectionBindSuccess       uint16 = 0x010B
	ConnectionBindError         uint16 = 0x011B
	ConnectionAttemptIndication uint16 = 0x001C // RFC 6062 §4.4, server → client
)

// Attributes.
const (
	AttrUsername           uint16 = 0x0006
	AttrMessageIntegrity   uint16 = 0x0008
	AttrErrorCode          uint16 = 0x0009
	AttrChannelNumber      uint16 = 0x000C
	AttrLifetime           uint16 = 0x000D
	AttrXorPeerAddress     uint16 = 0x0012
	AttrData               uint16 = 0x0013
	AttrRealm              uint16 = 0x0014
	AttrNonce              uint16 = 0x0015
	AttrXorRelayedAddress  uint16 = 0x0016
	AttrRequestedTransport uint16 = 0x0019
	AttrXorMappedAddress   uint16 = 0x0020
	AttrConnectionID       uint16 = 0x002A
	AttrFingerprint        uint16 = 0x8028
)

// Magic is the RFC 5389 magic cookie.
const Magic uint32 = 0x2112A442

// REQUESTED-TRANSPORT protocol numbers.
const (
	ProtoTCP uint8 = 6
	ProtoUDP uint8 = 17
)

// fingerprintXOR is what FINGERPRINT's CRC-32 is XORed with (RFC 5389 §15.5).
const fingerprintXOR uint32 = 0x5354554e

var magicBytes = [4]byte{0x21, 0x12, 0xA4, 0x42}

// Attr is one attribute, value unpadded.
type Attr struct {
	Type  uint16
	Value []byte
}

// Message is a STUN message; attributes keep their insertion order.
type Message struct {
	Type  uint16
	TxID  [12]byte
	Attrs []Attr
}

// New is a message of type t with a fresh random transaction id.
func New(t uint16) *Message {
	m := &Message{Type: t}
	_, _ = rand.Read(m.TxID[:])
	return m
}

// NewWithTxID is a message with a given transaction id (tests, responses).
func NewWithTxID(t uint16, txid [12]byte) *Message { return &Message{Type: t, TxID: txid} }

func (m *Message) IsSuccess() bool    { return m.Type&0x0110 == 0x0100 }
func (m *Message) IsError() bool      { return m.Type&0x0110 == 0x0110 }
func (m *Message) IsIndication() bool { return m.Type&0x0110 == 0x0010 }

// Add appends an attribute.
func (m *Message) Add(t uint16, v []byte) {
	m.Attrs = append(m.Attrs, Attr{t, append([]byte(nil), v...)})
}

// AddString appends a UTF-8 attribute.
func (m *Message) AddString(t uint16, s string) { m.Add(t, []byte(s)) }

// AddU32 appends a big-endian 32-bit attribute.
func (m *Message) AddU32(t uint16, v uint32) {
	var b [4]byte
	binary.BigEndian.PutUint32(b[:], v)
	m.Add(t, b[:])
}

// AddChannelNumber appends CHANNEL-NUMBER (channel + 2 bytes RFFU).
func (m *Message) AddChannelNumber(ch uint16) {
	m.Add(AttrChannelNumber, []byte{byte(ch >> 8), byte(ch), 0, 0})
}

// AddErrorCode appends ERROR-CODE (RFC 5389 §15.6): class/number + reason.
func (m *Message) AddErrorCode(code int, reason string) {
	v := []byte{0, 0, byte(code/100) & 0x07, byte(code % 100)}
	m.Add(AttrErrorCode, append(v, reason...))
}

// AddXorAddress appends an XOR-*-ADDRESS (RFC 5389 §15.2): port ^ magic>>16;
// v4 addr ^ magic, v6 addr ^ (magic || txid). False for an unparseable IP.
func (m *Message) AddXorAddress(t uint16, ip string, port int) bool {
	v, ok := XorAddressValue(ip, port, m.TxID)
	if !ok {
		return false
	}
	m.Add(t, v)
	return true
}

// XorAddressValue is the attribute value AddXorAddress would append.
func XorAddressValue(ip string, port int, txid [12]byte) ([]byte, bool) {
	addr := net.ParseIP(ip)
	if addr == nil {
		return nil, false
	}
	xport := uint16(port) ^ uint16(Magic>>16)
	key := append(magicBytes[:], txid[:]...)
	if v4 := addr.To4(); v4 != nil && !isV6Literal(ip) {
		v := []byte{0, 0x01, byte(xport >> 8), byte(xport)}
		for i := 0; i < 4; i++ {
			v = append(v, v4[i]^key[i])
		}
		return v, true
	}
	v6 := addr.To16()
	v := []byte{0, 0x02, byte(xport >> 8), byte(xport)}
	for i := 0; i < 16; i++ {
		v = append(v, v6[i]^key[i])
	}
	return v, true
}

// isV6Literal: "::ffff:1.2.3.4" parses as v4 in Go but inet_pton(AF_INET)
// refuses it, so the Swift encodes it as family 0x02.
func isV6Literal(ip string) bool {
	for i := 0; i < len(ip); i++ {
		if ip[i] == ':' {
			return true
		}
	}
	return false
}

// Encode serializes header + attributes, each padded with zeros to a 4-byte
// boundary; an attribute's length field counts the unpadded value.
func (m *Message) Encode() []byte {
	var body []byte
	for _, a := range m.Attrs {
		body = append(body, byte(a.Type>>8), byte(a.Type), byte(len(a.Value)>>8), byte(len(a.Value)))
		body = append(body, a.Value...)
		for len(body)%4 != 0 {
			body = append(body, 0)
		}
	}
	out := make([]byte, 0, 20+len(body))
	out = append(out, byte(m.Type>>8), byte(m.Type), byte(len(body)>>8), byte(len(body)))
	out = append(out, magicBytes[:]...)
	out = append(out, m.TxID[:]...)
	return append(out, body...)
}

// LongTermKey is MD5(username ":" realm ":" password). SASLprep is skipped,
// as in the Swift: the REST-API username and realm are plain ASCII.
func LongTermKey(username, realm, password string) []byte {
	h := md5.Sum([]byte(username + ":" + realm + ":" + password))
	return h[:]
}

// Sign appends MESSAGE-INTEGRITY: HMAC-SHA1 over the message up to the
// attribute, with the header length already counting its 24 bytes.
func (m *Message) Sign(key []byte) {
	m.Add(AttrMessageIntegrity, integrity(m.Encode(), key))
}

func integrity(encoded []byte, key []byte) []byte {
	b := append([]byte(nil), encoded...)
	withMI := len(b) - 20 + 24
	b[2], b[3] = byte(withMI>>8), byte(withMI)
	mac := hmac.New(sha1.New, key)
	mac.Write(b)
	return mac.Sum(nil)
}

// AddFingerprint appends FINGERPRINT: CRC-32 of the message up to the
// attribute (length counting its 8 bytes) XOR 0x5354554e. The Swift never
// emits it; the test relay does.
func (m *Message) AddFingerprint() {
	b := m.Encode()
	withFP := len(b) - 20 + 8
	b[2], b[3] = byte(withFP>>8), byte(withFP)
	m.AddU32(AttrFingerprint, crc32.ChecksumIEEE(b)^fingerprintXOR)
}

// VerifyIntegrity checks a decoded message's MESSAGE-INTEGRITY with key
// (raw is the message as received). False when absent or wrong.
func VerifyIntegrity(raw []byte, key []byte) bool {
	off, ok := attrOffset(raw, AttrMessageIntegrity)
	if !ok || off+4+20 > len(raw) {
		return false
	}
	want := raw[off+4 : off+24]
	return hmac.Equal(integrity(raw[:off], key), want)
}

// VerifyFingerprint checks a raw message's FINGERPRINT (false when absent).
func VerifyFingerprint(raw []byte) bool {
	off, ok := attrOffset(raw, AttrFingerprint)
	if !ok || off+8 > len(raw) {
		return false
	}
	b := append([]byte(nil), raw[:off]...)
	withFP := len(b) - 20 + 8
	b[2], b[3] = byte(withFP>>8), byte(withFP)
	return binary.BigEndian.Uint32(raw[off+4:off+8]) == crc32.ChecksumIEEE(b)^fingerprintXOR
}

func attrOffset(raw []byte, t uint16) (int, bool) {
	if len(raw) < 20 {
		return 0, false
	}
	end := 20 + int(binary.BigEndian.Uint16(raw[2:4]))
	if end > len(raw) {
		return 0, false
	}
	off := 20
	for off+4 <= end {
		at := binary.BigEndian.Uint16(raw[off:])
		l := int(binary.BigEndian.Uint16(raw[off+2:]))
		if at == t {
			return off, true
		}
		off += 4 + l
		for off%4 != 0 {
			off++
		}
	}
	return 0, false
}

// Decode parses one complete message (already framed off the stream via the
// header length). nil on bad magic or framing; a truncated attribute ends
// the list, as in the Swift.
func Decode(b []byte) *Message {
	if len(b) < 20 {
		return nil
	}
	t := binary.BigEndian.Uint16(b[0:2])
	if t&0xC000 != 0 {
		return nil
	}
	length := int(binary.BigEndian.Uint16(b[2:4]))
	if binary.BigEndian.Uint32(b[4:8]) != Magic || len(b) < 20+length {
		return nil
	}
	m := &Message{Type: t}
	copy(m.TxID[:], b[8:20])
	off, end := 20, 20+length
	for off+4 <= end {
		at := binary.BigEndian.Uint16(b[off:])
		l := int(binary.BigEndian.Uint16(b[off+2:]))
		if off+4+l > end {
			break
		}
		m.Attrs = append(m.Attrs, Attr{at, append([]byte(nil), b[off+4:off+4+l]...)})
		off += 4 + l
		for off%4 != 0 {
			off++
		}
	}
	return m
}

// Attr returns the first attribute of type t.
func (m *Message) Attr(t uint16) ([]byte, bool) {
	for _, a := range m.Attrs {
		if a.Type == t {
			return a.Value, true
		}
	}
	return nil, false
}

// String returns an attribute as text.
func (m *Message) String(t uint16) (string, bool) {
	v, ok := m.Attr(t)
	return string(v), ok
}

// U32 returns a 32-bit attribute.
func (m *Message) U32(t uint16) (uint32, bool) {
	v, ok := m.Attr(t)
	if !ok || len(v) < 4 {
		return 0, false
	}
	return binary.BigEndian.Uint32(v), true
}

// ErrorCode is ERROR-CODE as class×100+number (401, 438…); 0 when absent.
func (m *Message) ErrorCode() int {
	v, ok := m.Attr(AttrErrorCode)
	if !ok || len(v) < 4 {
		return 0
	}
	return int(v[2]&0x07)*100 + int(v[3])
}

// XorAddress un-XORs an XOR-*-ADDRESS back to (ip, port).
func (m *Message) XorAddress(t uint16) (string, int, bool) {
	v, ok := m.Attr(t)
	if !ok || len(v) < 8 {
		return "", 0, false
	}
	key := append(magicBytes[:], m.TxID[:]...)
	port := int(binary.BigEndian.Uint16(v[2:4]) ^ uint16(Magic>>16))
	switch v[1] {
	case 0x01:
		a := make(net.IP, 4)
		for i := range a {
			a[i] = v[4+i] ^ key[i]
		}
		return a.String(), port, true
	case 0x02:
		if len(v) < 20 {
			return "", 0, false
		}
		a := make(net.IP, 16)
		for i := range a {
			a[i] = v[4+i] ^ key[i]
		}
		return a.String(), port, true
	}
	return "", 0, false
}

// HostPort formats ip:port for logs and dials.
func HostPort(ip string, port int) string { return net.JoinHostPort(ip, strconv.Itoa(port)) }
