// Package sshserver is the Sidecar's embedded SSH server
// (RemoteAccessServer.swift + RemoteSSHHandlers.swift): loopback only
// (devices come in through the bromure.io relay, which this machine dials
// out to), public keys only, the SSH user must be the local user. Session
// channels only; their exec verbs bridge to the control socket, park
// delegation-MCP channels in the hub, or attach machines; a shell (or any
// other command) gets the remote menu.
package sshserver

import (
	"errors"
	"fmt"
	"net"
	"strconv"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/rderaison/bromure/sidecar/internal/delegation"
	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/panes"
)

// Config is the server's.
type Config struct {
	// Port on 127.0.0.1 (settings.SSHPortValue()); 0 picks a free one.
	Port int
	// User is the one SSH user name accepted: the bare local user name
	// (%USERNAME%, never DOMAIN\user).
	User string
	// ControlSocket is control.sock, which `bromure-fatclient/1 control`
	// (and the machine verbs) bridge to.
	ControlSocket string
	// Hub parks `delegation-mcp` channels; nil refuses them.
	Hub *delegation.Hub
	// Panes opens a pane host client for the remote menu (a shell). The
	// menu owns the client and closes it when it ends. nil: no menu.
	Panes func() (panes.Client, error)
}

// Server is a running SSH server.
type Server struct {
	cfg    Config
	ln     net.Listener
	signer ssh.Signer

	mu     sync.Mutex
	keys   keySet
	conns  map[net.Conn]bool
	closed bool
}

var (
	runMu   sync.Mutex
	running = map[*Server]bool{}
)

// reloadRunning hot-swaps the key set into every running server: new
// connections see it; live ones (past auth) are undisturbed.
func reloadRunning() {
	runMu.Lock()
	list := make([]*Server, 0, len(running))
	for s := range running {
		list = append(list, s)
	}
	runMu.Unlock()
	if len(list) == 0 {
		return
	}
	ks := loadKeySet()
	for _, s := range list {
		s.mu.Lock()
		s.keys = ks
		s.mu.Unlock()
	}
}

// Start listens on 127.0.0.1:Port and serves until Close.
func Start(cfg Config) (*Server, error) {
	if cfg.User == "" {
		return nil, errors.New("sshserver: no user name")
	}
	signer, err := loadOrCreateHostKey()
	if err != nil {
		return nil, fmt.Errorf("Couldn't generate host key: %w", err)
	}
	ln, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(cfg.Port)))
	if err != nil {
		return nil, fmt.Errorf("Couldn't start the SSH server: couldn't bind 127.0.0.1:%d: %w", cfg.Port, err)
	}
	s := &Server{cfg: cfg, ln: ln, signer: signer, keys: loadKeySet(), conns: map[net.Conn]bool{}}
	runMu.Lock()
	running[s] = true
	runMu.Unlock()
	go s.acceptLoop()
	logx.Printf("[remote] embedded SSH server listening on %s.", ln.Addr())
	return s, nil
}

// Addr is the listening address.
func (s *Server) Addr() net.Addr { return s.ln.Addr() }

// Close stops listening and drops every connection.
func (s *Server) Close() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	conns := s.conns
	s.conns = map[net.Conn]bool{}
	s.mu.Unlock()
	runMu.Lock()
	delete(running, s)
	runMu.Unlock()
	_ = s.ln.Close()
	for c := range conns {
		_ = c.Close()
	}
}

// Key management, applied to this (and any) running server without a restart.
func (s *Server) AddAuthorizedKey(line string) error        { return AddAuthorizedKey(line) }
func (s *Server) RemoveAuthorizedKey(selector string) error { return RemoveAuthorizedKey(selector) }
func (s *Server) SetManagedKeys(marker string, lines []string) {
	SetManagedKeys(marker, lines)
}
func (s *Server) ListAuthorizedKeys() []AuthorizedKey { return ListAuthorizedKeys() }
func (s *Server) HostKeyFingerprint() string          { return HostKeyFingerprint() }
func (s *Server) HostPublicKeyLine() string           { return HostPublicKeyLine() }

func (s *Server) acceptLoop() {
	for {
		c, err := s.ln.Accept()
		if err != nil {
			s.mu.Lock()
			closed := s.closed
			s.mu.Unlock()
			if closed {
				return
			}
			if ne, ok := err.(net.Error); ok && ne.Timeout() {
				continue
			}
			logx.Printf("[remote] accept: %v", err)
			time.Sleep(100 * time.Millisecond)
			continue
		}
		// Reap dead peers: first probe after 60 s idle, then every 30 s,
		// 4 misses (~3 min) drops the connection and everything on it.
		if tc, ok := c.(*net.TCPConn); ok {
			_ = tc.SetKeepAliveConfig(net.KeepAliveConfig{Enable: true, Idle: 60 * time.Second, Interval: 30 * time.Second, Count: 4})
			_ = tc.SetNoDelay(true)
		}
		s.mu.Lock()
		if s.closed {
			s.mu.Unlock()
			_ = c.Close()
			return
		}
		s.conns[c] = true
		s.mu.Unlock()
		go s.serveConn(c)
	}
}

// grantMachine is the permissions extension carrying a machine-only key's
// device (RemoteGrant.machineOnly).
const grantMachine = "bromure-machine"

func (s *Server) serverConfig() *ssh.ServerConfig {
	cfg := &ssh.ServerConfig{
		PublicKeyCallback: func(meta ssh.ConnMetadata, key ssh.PublicKey) (*ssh.Permissions, error) {
			s.mu.Lock()
			ks := s.keys
			s.mu.Unlock()
			blob := string(key.Marshal())
			nameMatch := meta.User() == s.cfg.User
			inSet := ks.authorized[blob]
			ok := nameMatch && inSet
			verdict := "FAILURE"
			if ok {
				verdict = "SUCCESS"
			}
			logx.Printf("srv-auth: publickey user=%s nameMatch=%v inSet=%v keys=%d → %s",
				meta.User(), nameMatch, inSet, len(ks.authorized), verdict)
			if !ok {
				return nil, errors.New("not authorized")
			}
			perms := &ssh.Permissions{Extensions: map[string]string{}}
			if dev, isMachine := ks.machineOnly[blob]; isMachine {
				perms.Extensions[grantMachine] = dev
			}
			return perms, nil
		},
	}
	cfg.AddHostKey(s.signer)
	return cfg
}

func (s *Server) serveConn(c net.Conn) {
	defer func() {
		_ = c.Close()
		s.mu.Lock()
		delete(s.conns, c)
		s.mu.Unlock()
	}()
	// A peer that never finishes the handshake doesn't hold a goroutine
	// for ever.
	_ = c.SetDeadline(time.Now().Add(2 * time.Minute))
	sc, chans, reqs, err := ssh.NewServerConn(c, s.serverConfig())
	if err != nil {
		return
	}
	_ = c.SetDeadline(time.Time{})
	defer sc.Close()
	machine := ""
	if sc.Permissions != nil {
		machine = sc.Permissions.Extensions[grantMachine]
	}
	// No global requests (tcpip-forward, keepalives get a failure reply).
	go ssh.DiscardRequests(reqs)
	for nc := range chans {
		if nc.ChannelType() != "session" {
			_ = nc.Reject(ssh.UnknownChannelType, "only session channels")
			continue
		}
		go s.serveSession(nc, machine)
	}
}
