// Package turn is the TURN-over-TCP client (RFC 5766 long-term auth + RFC
// 6062 TCP allocations) and the relay listener the Sidecar serves through,
// ported from Sources/AgentCoding/P2P/{TurnTCP,TurnTLS,TurnRelayTransport}.swift.
// `turns:` is crypto/tls straight to the relay (SNI = the relay host) instead
// of the Swift's socketpair tunnel; the bytes on the wire are the same.
package turn

import (
	"context"
	"crypto/tls"
	"encoding/binary"
	"errors"
	"net"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/p2p/sockopt"
	"github.com/rderaison/bromure/sidecar/internal/p2p/stun"
)

// TLSConfig, when set, is cloned for every `turns:` leg (tests point RootCAs
// at their own relay). ServerName is always the relay host.
var TLSConfig *tls.Config

// Connect resolves (DNS ok) and connects within timeout, tuned for
// interactive use. With tlsOn the connection is TLS to the relay
// (validated against the system roots), keepalive on, a 30 s user timeout
// (the Swift's NWProtocolTCP connectionDropTime).
func Connect(host string, port int, timeout time.Duration, tlsOn bool) (net.Conn, error) {
	d := &net.Dialer{Timeout: timeout, KeepAliveConfig: sockopt.Keepalive}
	addr := net.JoinHostPort(host, strconv.Itoa(port))
	if !tlsOn {
		c, err := d.Dial("tcp", addr)
		if err != nil {
			return nil, err
		}
		sockopt.TuneInteractive(c, true)
		return c, nil
	}
	cfg := &tls.Config{MinVersion: tls.VersionTLS12}
	if TLSConfig != nil {
		cfg = TLSConfig.Clone()
	}
	cfg.ServerName = host
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	c, err := (&tls.Dialer{NetDialer: d, Config: cfg}).DialContext(ctx, "tcp", addr)
	if err != nil {
		return nil, err
	}
	sockopt.TuneInteractive(c, true)
	sockopt.SetUserTimeout(c, 30)
	return c, nil
}

// Framer reads whole STUN messages off a stream (RFC 5389 §7.2.2: the
// header's length says exactly how much more to read), never reading past
// one, so the raw peer bytes after a ConnectionBind success stay in the
// socket. A read that times out keeps what it had; the next continues it.
type Framer struct {
	Conn net.Conn
	buf  []byte
}

// Send writes one message.
func Send(c net.Conn, m *stun.Message) error {
	_, err := c.Write(m.Encode())
	return err
}

// Read returns the next message, waiting at most until deadline.
// errTimeout when nothing complete arrived in time.
func (f *Framer) Read(deadline time.Time) (*stun.Message, error) {
	_ = f.Conn.SetReadDeadline(deadline)
	defer f.Conn.SetReadDeadline(time.Time{})
	for {
		need := 20
		if len(f.buf) >= 20 {
			length := int(binary.BigEndian.Uint16(f.buf[2:4]))
			need = 20 + length
		}
		if len(f.buf) >= need {
			msg := f.buf[:need]
			f.buf = nil
			m := stun.Decode(msg)
			if m == nil {
				return nil, errors.New("turn: bad STUN framing")
			}
			return m, nil
		}
		chunk := make([]byte, need-len(f.buf))
		n, err := f.Conn.Read(chunk)
		f.buf = append(f.buf, chunk[:n]...)
		if err != nil {
			if errors.Is(err, os.ErrDeadlineExceeded) {
				return nil, ErrTimeout
			}
			return nil, err
		}
	}
}

// ErrTimeout: nothing arrived before the deadline.
var ErrTimeout = errors.New("turn: timed out")

// Allocation is a granted RFC 6062 TCP allocation.
type Allocation struct {
	RelayIP    string
	RelayPort  int
	MappedIP   string
	MappedPort int
	Lifetime   uint32
}

// Client is one TURN session (TurnTCPClient). The credentials are the TURN
// REST pair the control plane mints; auth is the 401 realm/nonce dance,
// re-signed on 438 (stale nonce).
type Client struct {
	Host     string
	Port     int
	TLS      bool
	username string
	password string

	mu      sync.Mutex
	realm   string
	nonce   string
	key     []byte
	pending []*stun.Message // indications seen while a transaction waited
	ctl     *Framer
}

// NewClient is a client for host:port.
func NewClient(host string, port int, tlsOn bool, username, password string) *Client {
	return &Client{Host: host, Port: port, TLS: tlsOn, username: username, password: password}
}

// Connect opens the control connection.
func (c *Client) Connect(timeout time.Duration) error {
	c.mu.Lock()
	have := c.ctl != nil
	c.mu.Unlock()
	if have {
		return nil
	}
	conn, err := Connect(c.Host, c.Port, timeout, c.TLS)
	if err != nil {
		return err
	}
	c.mu.Lock()
	c.ctl = &Framer{Conn: conn}
	c.mu.Unlock()
	return nil
}

// Close drops the control connection (waking a blocked read).
func (c *Client) Close() {
	c.mu.Lock()
	f := c.ctl
	c.ctl = nil
	c.mu.Unlock()
	if f != nil {
		f.Conn.Close()
	}
}

func (c *Client) control() *Framer {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.ctl
}

// AllocateRequest is the bare Allocate (REQUESTED-TRANSPORT TCP).
func AllocateRequest() *stun.Message {
	m := stun.New(stun.AllocateRequest)
	m.Add(stun.AttrRequestedTransport, []byte{stun.ProtoTCP, 0, 0, 0})
	return m
}

// CreatePermissionRequest is the bare CreatePermission for peerIP (port 0;
// permissions ignore it). nil for an unparseable IP.
func CreatePermissionRequest(peerIP string) *stun.Message {
	m := stun.New(stun.CreatePermissionRequest)
	if !m.AddXorAddress(stun.AttrXorPeerAddress, peerIP, 0) {
		return nil
	}
	return m
}

// RefreshRequest is the bare Refresh (no LIFETIME: the server's default).
func RefreshRequest() *stun.Message { return stun.New(stun.RefreshRequest) }

// ConnectionBindRequest binds a data connection to a ConnectionAttempt.
func ConnectionBindRequest(id uint32) *stun.Message {
	m := stun.New(stun.ConnectionBindRequest)
	m.AddU32(stun.AttrConnectionID, id)
	return m
}

// ConnectRequest is RFC 6062 §4.3's client-initiated Connect to a peer.
// The Swift never sends it (the dialer reaches the relayed address with a
// plain TCP connect); kept for the codec and its golden test.
func ConnectRequest(peerIP string, peerPort int) *stun.Message {
	m := stun.New(stun.ConnectRequest)
	if !m.AddXorAddress(stun.AttrXorPeerAddress, peerIP, peerPort) {
		return nil
	}
	return m
}

// AllocateTCP requests the RFC 6062 TCP allocation.
func (c *Client) AllocateTCP(timeout time.Duration) (Allocation, error) {
	f := c.control()
	resp, err := c.transact(f, timeout, func() *stun.Message { return AllocateRequest() })
	if err != nil {
		return Allocation{}, err
	}
	if !resp.IsSuccess() {
		return Allocation{}, errors.New("turn: allocate refused (" + strconv.Itoa(resp.ErrorCode()) + ")")
	}
	rip, rport, ok1 := resp.XorAddress(stun.AttrXorRelayedAddress)
	mip, mport, ok2 := resp.XorAddress(stun.AttrXorMappedAddress)
	if !ok1 || !ok2 {
		return Allocation{}, errors.New("turn: allocate response without addresses")
	}
	life, ok := resp.U32(stun.AttrLifetime)
	if !ok {
		life = 600
	}
	return Allocation{rip, rport, mip, mport, life}, nil
}

// CreatePermission lets relayed connections in from peerIP.
func (c *Client) CreatePermission(peerIP string, timeout time.Duration) bool {
	resp, err := c.transact(c.control(), timeout, func() *stun.Message { return CreatePermissionRequest(peerIP) })
	return err == nil && resp.IsSuccess()
}

// Refresh renews the allocation; the granted lifetime, or false (over).
func (c *Client) Refresh(timeout time.Duration) (uint32, bool) {
	resp, err := c.transact(c.control(), timeout, RefreshRequest)
	if err != nil || !resp.IsSuccess() {
		return 0, false
	}
	life, ok := resp.U32(stun.AttrLifetime)
	if !ok {
		life = 600
	}
	return life, true
}

// BindDataConnection opens a second connection to the relay and binds it
// to a ConnectionAttempt's id; on success it's a raw pipe to the peer.
func (c *Client) BindDataConnection(id uint32, timeout time.Duration) (net.Conn, error) {
	conn, err := Connect(c.Host, c.Port, timeout, c.TLS)
	if err != nil {
		return nil, err
	}
	resp, err := c.transact(&Framer{Conn: conn}, timeout, func() *stun.Message { return ConnectionBindRequest(id) })
	if err != nil || !resp.IsSuccess() {
		conn.Close()
		if err == nil {
			err = errors.New("turn: ConnectionBind refused (" + strconv.Itoa(resp.ErrorCode()) + ")")
		}
		return nil, err
	}
	return conn, nil
}

// ReadEvent waits for the next server → client indication on the control
// connection; stray responses are dropped. ErrTimeout is normal.
func (c *Client) ReadEvent(timeout time.Duration) (*stun.Message, error) {
	c.mu.Lock()
	if len(c.pending) > 0 {
		ev := c.pending[0]
		c.pending = c.pending[1:]
		c.mu.Unlock()
		return ev, nil
	}
	c.mu.Unlock()
	f := c.control()
	if f == nil {
		return nil, net.ErrClosed
	}
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		m, err := f.Read(deadline)
		if err != nil {
			return nil, err
		}
		if m.IsIndication() {
			return m, nil
		}
	}
	return nil, ErrTimeout
}

// transact sends one request and waits for its reply, running the
// long-term-credential dance: the first 401 teaches realm+nonce, a 438
// rotates the nonce; each retry is a fresh transaction (≤3).
func (c *Client) transact(f *Framer, timeout time.Duration, build func() *stun.Message) (*stun.Message, error) {
	if f == nil {
		return nil, net.ErrClosed
	}
	for retries := 0; retries < 3; retries++ {
		msg := build()
		if msg == nil {
			return nil, errors.New("turn: bad request")
		}
		c.mu.Lock()
		haveKey := len(c.key) > 0
		if haveKey {
			msg.AddString(stun.AttrUsername, c.username)
			msg.AddString(stun.AttrRealm, c.realm)
			msg.AddString(stun.AttrNonce, c.nonce)
			msg.Sign(c.key)
		}
		c.mu.Unlock()
		if err := Send(f.Conn, msg); err != nil {
			return nil, err
		}
		deadline := time.Now().Add(timeout)
		var resp *stun.Message
		for time.Now().Before(deadline) {
			m, err := f.Read(deadline)
			if err != nil {
				break
			}
			if m.IsIndication() {
				c.mu.Lock()
				c.pending = append(c.pending, m)
				c.mu.Unlock()
				continue
			}
			if m.TxID == msg.TxID {
				resp = m
				break
			}
		}
		if resp == nil {
			return nil, ErrTimeout
		}
		code := resp.ErrorCode()
		if (code == 401 && !haveKey) || code == 438 {
			realm, ok := resp.String(stun.AttrRealm)
			if !ok {
				c.mu.Lock()
				realm, ok = c.realm, c.realm != ""
				c.mu.Unlock()
			}
			nonce, nok := resp.String(stun.AttrNonce)
			if !ok || !nok {
				return resp, nil
			}
			c.mu.Lock()
			c.realm, c.nonce = realm, nonce
			c.key = stun.LongTermKey(c.username, realm, c.password)
			c.mu.Unlock()
			continue
		}
		return resp, nil
	}
	return nil, errors.New("turn: authentication failed")
}

// PublicAddress is our public address as host sees it: STUN Binding over
// TCP first (same protocol and NAT mapping family as the relay legs), then
// UDP with the remaining budget.
func PublicAddress(host string, port int, timeout time.Duration) (string, int, bool) {
	deadline := time.Now().Add(timeout)
	tcpDeadline := time.Now().Add(timeout / 2)
	if ip, p, ok := bindingTCP(host, port, tcpDeadline); ok {
		return ip, p, true
	}
	return BindingUDP(host, port, deadline)
}

func bindingTCP(host string, port int, deadline time.Time) (string, int, bool) {
	conn, err := Connect(host, port, time.Until(deadline), false)
	if err != nil {
		return "", 0, false
	}
	defer conn.Close()
	req := stun.New(stun.BindingRequest)
	if Send(conn, req) != nil {
		return "", 0, false
	}
	f := &Framer{Conn: conn}
	for {
		resp, err := f.Read(deadline)
		if err != nil {
			return "", 0, false
		}
		if resp.TxID != req.TxID || !resp.IsSuccess() {
			continue
		}
		return resp.XorAddress(stun.AttrXorMappedAddress)
	}
}

// BindingUDP is one STUN Binding over UDP with RFC 5389 retransmits (500 ms
// initial RTO, doubling) until deadline. A connected socket surfaces ICMP
// unreachable as a read error, so a dead server fails fast.
func BindingUDP(host string, port int, deadline time.Time) (string, int, bool) {
	conn, err := net.DialTimeout("udp", net.JoinHostPort(host, strconv.Itoa(port)), time.Until(deadline))
	if err != nil {
		return "", 0, false
	}
	defer conn.Close()
	req := stun.New(stun.BindingRequest)
	bytes := req.Encode()
	rto := 500 * time.Millisecond
	buf := make([]byte, 1500)
	for time.Now().Before(deadline) {
		if _, err := conn.Write(bytes); err != nil {
			return "", 0, false
		}
		wait := time.Now().Add(rto)
		if wait.After(deadline) {
			wait = deadline
		}
		_ = conn.SetReadDeadline(wait)
		for {
			n, err := conn.Read(buf)
			if err != nil {
				if errors.Is(err, os.ErrDeadlineExceeded) {
					break
				}
				return "", 0, false
			}
			if resp := stun.Decode(buf[:n]); resp != nil && resp.TxID == req.TxID && resp.IsSuccess() {
				return resp.XorAddress(stun.AttrXorMappedAddress)
			}
		}
		rto *= 2
	}
	return "", 0, false
}
