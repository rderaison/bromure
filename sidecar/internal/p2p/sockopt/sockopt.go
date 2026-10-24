// Package sockopt is SocketTuning from Sources/AgentCoding/P2P/P2PTransport.swift
// for Go sockets: TCP_NODELAY, keepalive 15 s idle / 5 s interval / 3 probes
// (a silently dead link is noticed in ~30 s), and a per-OS "user timeout"
// (how long unacknowledged data may sit before the connection is dropped):
// TCP_MAXRT on Windows, TCP_USER_TIMEOUT on Linux, TCP_RXT_CONNDROPTIME on
// macOS (what the Swift sets).
package sockopt

import (
	"crypto/tls"
	"net"
	"time"
)

// Keepalive matches the Swift's TCP_KEEPALIVE/KEEPINTVL/KEEPCNT.
var Keepalive = net.KeepAliveConfig{Enable: true, Idle: 15 * time.Second, Interval: 5 * time.Second, Count: 3}

// tcpOf unwraps a TLS connection to its TCP socket.
func tcpOf(c net.Conn) *net.TCPConn {
	for {
		switch v := c.(type) {
		case *net.TCPConn:
			return v
		case *tls.Conn:
			c = v.NetConn()
		default:
			return nil
		}
	}
}

// TuneInteractive disables Nagle and, with keepalive, enables the ~30 s
// dead-link detection. A no-op on anything that isn't TCP underneath.
func TuneInteractive(c net.Conn, keepalive bool) {
	t := tcpOf(c)
	if t == nil {
		return
	}
	_ = t.SetNoDelay(true)
	if keepalive {
		_ = t.SetKeepAliveConfig(Keepalive)
	}
}

// SetUserTimeout drops the connection after secs of unacknowledged data
// (best effort; errors are ignored like the Swift's setsockopt calls).
func SetUserTimeout(c net.Conn, secs int) {
	t := tcpOf(c)
	if t == nil {
		return
	}
	raw, err := t.SyscallConn()
	if err != nil {
		return
	}
	_ = raw.Control(func(fd uintptr) { setUserTimeout(fd, secs) })
}

// StallWrite is the per-write send timeout on a relay leg (SO_SNDTIMEO 15 s
// in the Swift) and MaxWriteStalls how many in a row without progress mark
// the far peer dead (FatForward.maxWriteStalls).
const (
	StallWrite     = 15 * time.Second
	MaxWriteStalls = 4
)

// BoundStalledPeer is the Swift's boundStalledPeer for the retransmit half:
// drop a relay leg after 60 s of failed retransmits. The send-timeout half
// is the splice's write deadline (StallWrite × MaxWriteStalls).
func BoundStalledPeer(c net.Conn) { SetUserTimeout(c, 60) }
