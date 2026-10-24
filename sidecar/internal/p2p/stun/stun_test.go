package stun

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The fixtures in testdata/ are laid out by hand from the Swift encoder by
// testdata/gen_fixtures.py (Python's hashlib/hmac/zlib for the MACs): the
// Go encoder must reproduce them byte for byte and the decoder parse them.

var txid = [12]byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}

const (
	user  = "1700000000:conn-1"
	realm = "bromure.io"
	nonce = "abcdef0123456789"
	pass  = "s3cret-pass"
)

func fixture(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("testdata", name+".hex"))
	if err != nil {
		t.Fatal(err)
	}
	var h strings.Builder
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		h.WriteString(line)
	}
	b, err := hex.DecodeString(h.String())
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// signLikeTransact adds the auth attributes in TurnTCPClient.transact's order.
func signLikeTransact(m *Message) {
	m.AddString(AttrUsername, user)
	m.AddString(AttrRealm, realm)
	m.AddString(AttrNonce, nonce)
	m.Sign(LongTermKey(user, realm, pass))
}

func xor(t *testing.T, m *Message, typ uint16, ip string, port int) {
	if !m.AddXorAddress(typ, ip, port) {
		t.Fatalf("bad ip %s", ip)
	}
}

func TestGoldenEncode(t *testing.T) {
	u32 := func(v uint32) []byte { b := make([]byte, 4); binary.BigEndian.PutUint32(b, v); return b }
	cases := map[string]func() *Message{
		"binding_request": func() *Message { return NewWithTxID(BindingRequest, txid) },
		"binding_success_v4": func() *Message {
			m := NewWithTxID(BindingSuccess, txid)
			xor(t, m, AttrXorMappedAddress, "203.0.113.7", 54321)
			return m
		},
		"binding_success_v6": func() *Message {
			m := NewWithTxID(BindingSuccess, txid)
			xor(t, m, AttrXorMappedAddress, "2001:db8::1", 443)
			return m
		},
		"allocate_noauth": func() *Message {
			m := NewWithTxID(AllocateRequest, txid)
			m.Add(AttrRequestedTransport, []byte{ProtoTCP, 0, 0, 0})
			return m
		},
		"allocate_401": func() *Message {
			m := NewWithTxID(AllocateError, txid)
			m.AddErrorCode(401, "Unauthorized")
			m.AddString(AttrRealm, realm)
			m.AddString(AttrNonce, nonce)
			return m
		},
		"allocate_438": func() *Message {
			m := NewWithTxID(AllocateError, txid)
			m.AddErrorCode(438, "Stale Nonce")
			m.AddString(AttrNonce, "fedcba9876543210")
			return m
		},
		"allocate_auth": func() *Message {
			m := NewWithTxID(AllocateRequest, txid)
			m.Add(AttrRequestedTransport, []byte{ProtoTCP, 0, 0, 0})
			signLikeTransact(m)
			return m
		},
		"allocate_success": func() *Message {
			m := NewWithTxID(AllocateSuccess, txid)
			xor(t, m, AttrXorRelayedAddress, "203.0.113.50", 49152)
			xor(t, m, AttrXorMappedAddress, "198.51.100.20", 61000)
			m.AddU32(AttrLifetime, 600)
			return m
		},
		"create_permission_auth": func() *Message {
			m := NewWithTxID(CreatePermissionRequest, txid)
			xor(t, m, AttrXorPeerAddress, "198.51.100.20", 0)
			signLikeTransact(m)
			return m
		},
		"refresh_auth": func() *Message {
			m := NewWithTxID(RefreshRequest, txid)
			signLikeTransact(m)
			return m
		},
		"connection_bind_auth": func() *Message {
			m := NewWithTxID(ConnectionBindRequest, txid)
			m.Add(AttrConnectionID, u32(0x12345678))
			signLikeTransact(m)
			return m
		},
		"connect_auth": func() *Message {
			m := NewWithTxID(ConnectRequest, txid)
			xor(t, m, AttrXorPeerAddress, "198.51.100.20", 2223)
			signLikeTransact(m)
			return m
		},
		"connection_attempt": func() *Message {
			m := NewWithTxID(ConnectionAttemptIndication, txid)
			m.AddU32(AttrConnectionID, 0x12345678)
			xor(t, m, AttrXorPeerAddress, "198.51.100.20", 61001)
			return m
		},
		"binding_request_fingerprint": func() *Message {
			m := NewWithTxID(BindingRequest, txid)
			m.AddFingerprint()
			return m
		},
		"refresh_auth_fingerprint": func() *Message {
			m := NewWithTxID(RefreshRequest, txid)
			signLikeTransact(m)
			m.AddFingerprint()
			return m
		},
	}
	for name, build := range cases {
		t.Run(name, func(t *testing.T) {
			want := fixture(t, name)
			got := build().Encode()
			if !bytes.Equal(got, want) {
				t.Fatalf("encode mismatch\n got %x\nwant %x", got, want)
			}
			d := Decode(want)
			if d == nil {
				t.Fatal("decode failed")
			}
			if !bytes.Equal(d.Encode(), want) {
				t.Fatalf("decode/encode round trip differs")
			}
		})
	}
}

func TestLongTermKey(t *testing.T) {
	want := fixture(t, "longterm_key")
	if got := LongTermKey(user, realm, pass); !bytes.Equal(got, want) {
		t.Fatalf("key %x want %x", got, want)
	}
}

func TestGoldenDecode(t *testing.T) {
	m := Decode(fixture(t, "binding_success_v4"))
	if ip, port, ok := m.XorAddress(AttrXorMappedAddress); !ok || ip != "203.0.113.7" || port != 54321 {
		t.Fatalf("v4 %s %d %v", ip, port, ok)
	}
	m = Decode(fixture(t, "binding_success_v6"))
	if ip, port, ok := m.XorAddress(AttrXorMappedAddress); !ok || ip != "2001:db8::1" || port != 443 {
		t.Fatalf("v6 %s %d %v", ip, port, ok)
	}
	m = Decode(fixture(t, "allocate_401"))
	if !m.IsError() || m.ErrorCode() != 401 {
		t.Fatalf("401: %v %d", m.IsError(), m.ErrorCode())
	}
	if r, _ := m.String(AttrRealm); r != realm {
		t.Fatalf("realm %q", r)
	}
	if n, _ := m.String(AttrNonce); n != nonce {
		t.Fatalf("nonce %q", n)
	}
	if m = Decode(fixture(t, "allocate_438")); m.ErrorCode() != 438 {
		t.Fatalf("438: %d", m.ErrorCode())
	}
	m = Decode(fixture(t, "allocate_success"))
	rip, rport, _ := m.XorAddress(AttrXorRelayedAddress)
	mip, mport, _ := m.XorAddress(AttrXorMappedAddress)
	life, _ := m.U32(AttrLifetime)
	if !m.IsSuccess() || rip != "203.0.113.50" || rport != 49152 || mip != "198.51.100.20" || mport != 61000 || life != 600 {
		t.Fatalf("allocate success: %s:%d %s:%d %d", rip, rport, mip, mport, life)
	}
	m = Decode(fixture(t, "connection_attempt"))
	id, _ := m.U32(AttrConnectionID)
	pip, pport, _ := m.XorAddress(AttrXorPeerAddress)
	if !m.IsIndication() || id != 0x12345678 || pip != "198.51.100.20" || pport != 61001 {
		t.Fatalf("attempt: %v %x %s:%d", m.IsIndication(), id, pip, pport)
	}
	key := LongTermKey(user, realm, pass)
	for _, n := range []string{"allocate_auth", "create_permission_auth", "refresh_auth", "connection_bind_auth", "connect_auth"} {
		if !VerifyIntegrity(fixture(t, n), key) {
			t.Fatalf("%s: integrity didn't verify", n)
		}
		if VerifyIntegrity(fixture(t, n), []byte("wrong")) {
			t.Fatalf("%s: wrong key verified", n)
		}
	}
	for _, n := range []string{"binding_request_fingerprint", "refresh_auth_fingerprint"} {
		if !VerifyFingerprint(fixture(t, n)) {
			t.Fatalf("%s: fingerprint didn't verify", n)
		}
	}
	if !VerifyIntegrity(fixture(t, "refresh_auth_fingerprint"), key) {
		t.Fatal("MI before FINGERPRINT didn't verify")
	}
}

// RFC 5769 §2.1 sample request (short-term key, SOFTWARE padded with
// spaces): an independent check of the MESSAGE-INTEGRITY and FINGERPRINT
// computations against the RFC's own bytes.
func TestRFC5769SampleRequest(t *testing.T) {
	raw, _ := hex.DecodeString(strings.Join([]string{
		"000100582112a442b7e7a701bc34d686fa87dfae",
		"802200105354554e207465737420636c69656e74",
		"002400046e0001ff80290008932ff9b151263b36",
		"000600096576746a3a68367659202020",
		"000800149aeaa70cbfd8cb56781ef2b5b2d3f249c1b571a2",
		"80280004e57a3bcf",
	}, ""))
	if len(raw) != 108 {
		t.Skipf("sample length %d", len(raw))
	}
	if !VerifyIntegrity(raw, []byte("VOkJxbRl1RmTxUk/WvJxBt")) {
		t.Fatal("RFC 5769 MESSAGE-INTEGRITY didn't verify")
	}
	if !VerifyFingerprint(raw) {
		t.Fatal("RFC 5769 FINGERPRINT didn't verify")
	}
}

func TestDecodeRejects(t *testing.T) {
	good := fixture(t, "binding_request")
	if Decode(good[:19]) != nil {
		t.Fatal("short accepted")
	}
	bad := append([]byte(nil), good...)
	bad[4] = 0
	if Decode(bad) != nil {
		t.Fatal("bad magic accepted")
	}
	bad = append([]byte(nil), good...)
	bad[0] = 0x40 // ChannelData, not STUN
	if Decode(bad) != nil {
		t.Fatal("top bits accepted")
	}
	// A truncated attribute ends the list (the Swift breaks out).
	if Decode(fixture(t, "allocate_noauth")[:20]) != nil {
		t.Fatal("body shorter than the header length accepted")
	}
	trunc := fixture(t, "allocate_noauth")
	trunc[23] = 100 // REQUESTED-TRANSPORT claims 100 bytes
	if m := Decode(trunc); m == nil || len(m.Attrs) != 0 {
		t.Fatalf("truncated attribute: %+v", m)
	}
	if NewWithTxID(BindingRequest, txid).AddXorAddress(AttrXorPeerAddress, "not-an-ip", 1) {
		t.Fatal("bad ip accepted")
	}
}
