// Package turntest is an in-process fake TURN relay for tests: STUN
// Binding, RFC 5766 long-term auth (401 realm/nonce, optional 438 stale
// nonce), and RFC 6062 TCP allocations (Allocate, CreatePermission, Refresh,
// ConnectionAttempt on a peer connect, ConnectionBind on a data
// connection, then a raw splice). Responses carry MESSAGE-INTEGRITY and
// FINGERPRINT like coturn's. Loopback only; never a real relay.
package turntest

import (
	"crypto/tls"
	"encoding/binary"
	"io"
	"net"
	"strconv"
	"sync"

	"github.com/rderaison/bromure/sidecar/internal/p2p/stun"
)

// Server is the fake relay.
type Server struct {
	Host string
	Port int

	Realm, Nonce, Username, Password string
	// StaleNonceOnce answers the first signed request with 438.
	StaleNonceOnce bool
	// TLS, when set, serves turns: (the listener speaks TLS).
	TLS *tls.Config

	ln     net.Listener
	mu     sync.Mutex
	seen   []uint16
	msgs   []*stun.Message
	nextID uint32
	parked map[uint32]net.Conn
	staled bool
	allocs []*alloc
	closed bool
}

type alloc struct {
	ctl     net.Conn
	wmu     sync.Mutex
	relay   net.Listener
	perms   map[string]bool
	permsMu sync.Mutex
}

// Start listens on 127.0.0.1:0.
func Start(username, password string) (*Server, error) {
	s := &Server{Realm: "bromure.io", Nonce: "nonce-1", Username: username, Password: password, parked: map[uint32]net.Conn{}}
	return s, s.listen()
}

// StartTLS is Start with a TLS listener.
func StartTLS(username, password string, cfg *tls.Config) (*Server, error) {
	s := &Server{Realm: "bromure.io", Nonce: "nonce-1", Username: username, Password: password, parked: map[uint32]net.Conn{}, TLS: cfg}
	return s, s.listen()
}

func (s *Server) listen() error {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	if s.TLS != nil {
		ln = tls.NewListener(ln, s.TLS)
	}
	s.ln = ln
	a := ln.Addr().(*net.TCPAddr)
	s.Host, s.Port = "127.0.0.1", a.Port
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go s.serve(c)
		}
	}()
	return nil
}

// Close stops everything.
func (s *Server) Close() {
	s.mu.Lock()
	s.closed = true
	allocs := s.allocs
	s.mu.Unlock()
	s.ln.Close()
	for _, a := range allocs {
		a.relay.Close()
		a.ctl.Close()
	}
}

// Seen is the request types received, in order.
func (s *Server) Seen() []uint16 {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]uint16(nil), s.seen...)
}

// Requests is every request received, decoded, in order.
func (s *Server) Requests() []*stun.Message {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]*stun.Message(nil), s.msgs...)
}

func (s *Server) key() []byte { return stun.LongTermKey(s.Username, s.Realm, s.Password) }

func read(c net.Conn) ([]byte, *stun.Message, error) {
	h := make([]byte, 20)
	if _, err := io.ReadFull(c, h); err != nil {
		return nil, nil, err
	}
	body := make([]byte, binary.BigEndian.Uint16(h[2:4]))
	if _, err := io.ReadFull(c, body); err != nil {
		return nil, nil, err
	}
	raw := append(h, body...)
	return raw, stun.Decode(raw), nil
}

func (s *Server) reply(c net.Conn, mu *sync.Mutex, m *stun.Message, signed bool) {
	if signed {
		m.Sign(s.key())
	}
	m.AddFingerprint()
	if mu != nil {
		mu.Lock()
		defer mu.Unlock()
	}
	c.Write(m.Encode())
}

func errResp(req *stun.Message, code int, reason string) *stun.Message {
	m := stun.NewWithTxID(req.Type|0x0110, req.TxID)
	m.AddErrorCode(code, reason)
	return m
}

// authOK runs the long-term check; false = an error was sent.
func (s *Server) authOK(c net.Conn, mu *sync.Mutex, raw []byte, req *stun.Message) bool {
	if _, has := req.Attr(stun.AttrMessageIntegrity); !has {
		m := errResp(req, 401, "Unauthorized")
		m.AddString(stun.AttrRealm, s.Realm)
		m.AddString(stun.AttrNonce, s.Nonce)
		s.reply(c, mu, m, false)
		return false
	}
	u, _ := req.String(stun.AttrUsername)
	n, _ := req.String(stun.AttrNonce)
	if u != s.Username || !stun.VerifyIntegrity(raw, s.key()) {
		s.reply(c, mu, errResp(req, 401, "Unauthorized"), false)
		return false
	}
	s.mu.Lock()
	stale := s.StaleNonceOnce && !s.staled
	if stale {
		s.staled = true
		s.Nonce = "nonce-2"
	}
	cur := s.Nonce
	s.mu.Unlock()
	if stale || n != cur {
		m := errResp(req, 438, "Stale Nonce")
		m.AddString(stun.AttrRealm, s.Realm)
		m.AddString(stun.AttrNonce, cur)
		s.reply(c, mu, m, false)
		return false
	}
	return true
}

func addrOf(a net.Addr) (string, int) {
	t := a.(*net.TCPAddr)
	return t.IP.String(), t.Port
}

func (s *Server) serve(c net.Conn) {
	var al *alloc
	defer func() {
		if al == nil {
			c.Close()
		}
	}()
	for {
		raw, req, err := read(c)
		if err != nil || req == nil {
			if al != nil {
				al.relay.Close()
				c.Close()
			}
			return
		}
		s.mu.Lock()
		s.seen = append(s.seen, req.Type)
		s.msgs = append(s.msgs, req)
		s.mu.Unlock()
		var wmu *sync.Mutex
		if al != nil {
			wmu = &al.wmu
		}
		switch req.Type {
		case stun.BindingRequest:
			m := stun.NewWithTxID(stun.BindingSuccess, req.TxID)
			ip, port := addrOf(c.RemoteAddr())
			m.AddXorAddress(stun.AttrXorMappedAddress, ip, port)
			s.reply(c, wmu, m, false)
		case stun.AllocateRequest:
			if !s.authOK(c, wmu, raw, req) {
				continue
			}
			if rt, _ := req.Attr(stun.AttrRequestedTransport); len(rt) != 4 || rt[0] != stun.ProtoTCP {
				s.reply(c, wmu, errResp(req, 442, "Unsupported Transport Protocol"), true)
				continue
			}
			rl, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				return
			}
			al = &alloc{ctl: c, relay: rl, perms: map[string]bool{}}
			s.mu.Lock()
			s.allocs = append(s.allocs, al)
			s.mu.Unlock()
			go s.acceptPeers(al)
			m := stun.NewWithTxID(stun.AllocateSuccess, req.TxID)
			rip, rport := addrOf(rl.Addr())
			mip, mport := addrOf(c.RemoteAddr())
			m.AddXorAddress(stun.AttrXorRelayedAddress, rip, rport)
			m.AddXorAddress(stun.AttrXorMappedAddress, mip, mport)
			m.AddU32(stun.AttrLifetime, 600)
			s.reply(c, &al.wmu, m, true)
		case stun.CreatePermissionRequest:
			if al == nil {
				s.reply(c, wmu, errResp(req, 437, "Allocation Mismatch"), false)
				continue
			}
			if !s.authOK(c, wmu, raw, req) {
				continue
			}
			ip, _, ok := req.XorAddress(stun.AttrXorPeerAddress)
			if !ok {
				s.reply(c, wmu, errResp(req, 400, "Bad Request"), true)
				continue
			}
			al.permsMu.Lock()
			al.perms[ip] = true
			al.permsMu.Unlock()
			s.reply(c, wmu, stun.NewWithTxID(stun.CreatePermissionSuccess, req.TxID), true)
		case stun.RefreshRequest:
			if al == nil || !s.authOK(c, wmu, raw, req) {
				continue
			}
			m := stun.NewWithTxID(stun.RefreshSuccess, req.TxID)
			m.AddU32(stun.AttrLifetime, 600)
			s.reply(c, wmu, m, true)
		case stun.ConnectionBindRequest:
			if !s.authOK(c, nil, raw, req) {
				continue
			}
			id, _ := req.U32(stun.AttrConnectionID)
			s.mu.Lock()
			peer := s.parked[id]
			delete(s.parked, id)
			s.mu.Unlock()
			if peer == nil {
				s.reply(c, nil, errResp(req, 400, "Bad Request"), true)
				continue
			}
			s.reply(c, nil, stun.NewWithTxID(stun.ConnectionBindSuccess, req.TxID), true)
			go func() { io.Copy(peer, c); peer.Close() }()
			io.Copy(c, peer)
			c.Close()
			return
		default:
			s.reply(c, wmu, errResp(req, 400, "Bad Request"), false)
		}
	}
}

func (s *Server) acceptPeers(al *alloc) {
	for {
		p, err := al.relay.Accept()
		if err != nil {
			return
		}
		ip, port := addrOf(p.RemoteAddr())
		al.permsMu.Lock()
		ok := al.perms[ip]
		al.permsMu.Unlock()
		if !ok {
			p.Close() // no permission: coturn drops the connect
			continue
		}
		s.mu.Lock()
		s.nextID++
		id := s.nextID
		s.parked[id] = p
		s.mu.Unlock()
		m := stun.New(stun.ConnectionAttemptIndication)
		m.AddU32(stun.AttrConnectionID, id)
		m.AddXorAddress(stun.AttrXorPeerAddress, ip, port)
		s.reply(al.ctl, &al.wmu, m, false)
	}
}

// URLs is the coturn-style urls list for this relay.
func (s *Server) URLs() []string {
	scheme := "turn"
	if s.TLS != nil {
		scheme = "turns"
	}
	return []string{scheme + ":" + s.Host + ":" + strconv.Itoa(s.Port) + "?transport=tcp"}
}
