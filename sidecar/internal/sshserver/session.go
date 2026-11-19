package sshserver

import (
	"bytes"
	"encoding/json"
	"io"
	"net"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/rderaison/bromure/sidecar/internal/delegation"
	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/panes"
)

// session is one session channel (SSHPTYSessionHandler).
type session struct {
	srv     *Server
	ch      ssh.Channel
	machine string // set: a Sidecar's key, which may only attach its machine

	started atomic.Bool
	closed  atomic.Bool

	mu   sync.Mutex
	term string
	cols int
	rows int
	peer io.Closer        // the bridged stream, closed at teardown
	att  panes.Attachment // the menu's live attachment, resized on window-change
}

func (s *Server) serveSession(nc ssh.NewChannel, machine string) {
	ch, reqs, err := nc.Accept()
	if err != nil {
		return
	}
	ss := &session{srv: s, ch: ch, machine: machine, term: "xterm-256color", cols: 80, rows: 24}
	for req := range reqs {
		ss.handle(req)
	}
	// The channel is gone (closed, or its connection dropped): tear down.
	ss.closed.Store(true)
	ss.mu.Lock()
	peer := ss.peer
	ss.mu.Unlock()
	if peer != nil {
		_ = peer.Close()
	}
	_ = ch.Close()
}

func reply(req *ssh.Request, ok bool) {
	if req.WantReply {
		_ = req.Reply(ok, nil)
	}
}

func (ss *session) handle(req *ssh.Request) {
	switch req.Type {
	case "pty-req":
		var p struct {
			Term          string
			Cols, Rows    uint32
			Width, Height uint32
			Modes         string
		}
		if ssh.Unmarshal(req.Payload, &p) == nil {
			ss.mu.Lock()
			ss.term, ss.cols, ss.rows = p.Term, clampDim(p.Cols), clampDim(p.Rows)
			ss.mu.Unlock()
		}
		reply(req, true)
	case "window-change":
		var p struct{ Cols, Rows, Width, Height uint32 }
		if ssh.Unmarshal(req.Payload, &p) == nil {
			ss.mu.Lock()
			ss.cols, ss.rows = clampDim(p.Cols), clampDim(p.Rows)
			att, cols, rows := ss.att, ss.cols, ss.rows
			ss.mu.Unlock()
			if att != nil {
				_ = att.Resize(cols, rows)
			}
		}
		reply(req, true)
	case "shell":
		if ss.machine != "" {
			ss.refuse(req, "a shell")
			return
		}
		ss.startMenu(req)
	case "exec":
		var p struct{ Command string }
		if ssh.Unmarshal(req.Payload, &p) != nil {
			reply(req, false)
			return
		}
		ss.exec(req, p.Command)
	default:
		// env, subsystem, signal, x11-req, auth-agent-req…: not here.
		reply(req, false)
	}
}

func clampDim(v uint32) int {
	if v > 65535 {
		return 65535
	}
	return int(v)
}

func (ss *session) exec(req *ssh.Request, cmd string) {
	// A Bromure Sidecar's key attaches its machine, and that's all.
	owner := ""
	if ss.machine != "" {
		owner = "device:" + ss.machine
	}
	if id, name, ok := ParseMachineLink(cmd); ok {
		ss.startMachineLink(req, "/machines/link", id, &name, owner)
		return
	}
	if id, ok := ParseMachineDetach(cmd); ok {
		ss.startMachineLink(req, "/machines/detach", id, nil, owner)
		return
	}
	if owner != "" {
		ss.refuse(req, cmd)
		return
	}
	switch {
	case cmd == ControlVerb:
		ss.startControlBridge(req, nil)
	case isForward(cmd):
		ip, port, _ := ParseForward(cmd)
		ss.decline(req, "[remote] refused forward to "+ip+":"+strconv.Itoa(port)+" — not a guest on the vmnet subnet.")
	case isForwardUDP(cmd):
		ip, _ := ParseForwardUDP(cmd)
		ss.decline(req, "[remote] refused forward-udp to "+ip+" — not a guest on the vmnet subnet.")
	case isBrowserMCP(cmd):
		vm, _ := ParseBrowserMCP(cmd)
		ss.decline(req, "[remote] refused browser-mcp "+vm+" — no resolver.")
	case cmd == DelegationMCPVerb:
		ss.startDelegationMCP(req)
	default:
		// ForceCommand semantics: anything else runs the menu.
		ss.startMenu(req)
	}
}

func isForward(cmd string) bool    { _, _, ok := ParseForward(cmd); return ok }
func isForwardUDP(cmd string) bool { _, ok := ParseForwardUDP(cmd); return ok }
func isBrowserMCP(cmd string) bool { _, ok := ParseBrowserMCP(cmd); return ok }

// refuse: what a machine-only key may not do.
func (ss *session) refuse(req *ssh.Request, what string) {
	if len(what) > 60 {
		what = what[:60]
	}
	logx.Printf("srv: refused %s — an agent host's key may only attach its machine", what)
	reply(req, false)
	_ = ss.ch.Close()
}

func (ss *session) decline(req *ssh.Request, log string) {
	if !ss.started.CompareAndSwap(false, true) {
		return
	}
	logx.Printf("%s", log)
	reply(req, false)
	_ = ss.ch.Close()
}

// startMachineLink: the control socket, with the request written by us
// (the owner in it comes from this connection's grant, never the client),
// then a plain byte pipe.
func (ss *session) startMachineLink(req *ssh.Request, path, id string, name *string, owner string) {
	var body bytes.Buffer
	body.WriteString(`{"id":`)
	writeJSONString(&body, id)
	if name != nil {
		body.WriteString(`,"name":`)
		writeJSONString(&body, *name)
	}
	if owner != "" {
		body.WriteString(`,"owner":`)
		writeJSONString(&body, owner)
	}
	body.WriteString("}")
	head := "POST " + path + " HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: " +
		strconv.Itoa(body.Len()) + "\r\n\r\n"
	ss.startControlBridge(req, append([]byte(head), body.Bytes()...))
}

func writeJSONString(b *bytes.Buffer, s string) {
	enc := json.NewEncoder(b)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(s)
	b.Truncate(b.Len() - 1) // the encoder's newline
}

// startControlBridge: the channel becomes a raw byte pipe to control.sock
// (the fat client speaks the control HTTP API over it).
func (ss *session) startControlBridge(req *ssh.Request, preamble []byte) {
	if !ss.started.CompareAndSwap(false, true) {
		return
	}
	c, err := net.DialTimeout("unix", ss.srv.cfg.ControlSocket, 5*time.Second)
	if err != nil {
		logx.Printf("srv: control socket: %v", err)
		reply(req, false)
		_ = ss.ch.Close()
		return
	}
	if len(preamble) > 0 {
		if _, err := c.Write(preamble); err != nil {
			_ = c.Close()
			reply(req, false)
			_ = ss.ch.Close()
			return
		}
	}
	reply(req, true)
	ss.pump(c)
}

// startDelegationMCP parks the channel until an agent's MCP stream comes.
func (ss *session) startDelegationMCP(req *ssh.Request) {
	if !ss.started.CompareAndSwap(false, true) {
		return
	}
	hub := ss.srv.cfg.Hub
	if hub == nil {
		reply(req, false)
		_ = ss.ch.Close()
		return
	}
	// Accept now: the stream may be hours away, and the client's dial must
	// not time out waiting for the reply.
	reply(req, true)
	hub.Park(func(st delegation.Stream) bool {
		// A channel the client dropped while parked declines, so the
		// stream goes to the next one.
		if st == nil || ss.closed.Load() {
			return false
		}
		logx.Printf("delegation-mcp: stream -> channel")
		go ss.pump(st)
		return true
	}, nil)
}

type halfCloser interface {
	io.ReadWriteCloser
	CloseWrite() error
}

// pump bridges the channel and peer: channel → peer (the client's EOF
// becomes a write-half close), peer → channel (at the peer's EOF, every
// byte written, then exit-status 0 and the channel closes).
func (ss *session) pump(peer io.ReadWriteCloser) {
	ss.mu.Lock()
	ss.peer = peer
	ss.mu.Unlock()
	if ss.closed.Load() {
		_ = peer.Close()
		return
	}
	go func() {
		_, _ = io.Copy(peer, ss.ch)
		if hc, ok := peer.(halfCloser); ok {
			_ = hc.CloseWrite()
		}
	}()
	_, _ = io.Copy(ss.ch, peer)
	_ = peer.Close()
	ss.exit(0)
}

func (ss *session) exit(code int) {
	_, _ = ss.ch.SendRequest("exit-status", false, ssh.Marshal(struct{ Status uint32 }{uint32(code)}))
	_ = ss.ch.Close()
}
