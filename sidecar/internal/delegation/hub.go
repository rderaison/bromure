// Package delegation is where the agents' `bromure-delegation` MCP streams
// meet the Bromure AC that serves them (DelegationHub.swift), and the
// stdio shim agents run (`bromure-sidecar __mcp-delegation`,
// DelegationShim in DelegationHub.swift + DelegationShimStream/Calls).
//
// Each agent's shim connects to delegation.sock and says
// `bromure-hello w<window>`; a connected Bromure AC keeps a
// `delegation-mcp` channel parked here (an SSH exec channel, or a machine
// link's verb), and the hub splices the next stream into it: the
// delegation engine and every record live on that Mac. With no relay
// parked, a stream is answered here: the tool list, and a plain "not
// connected" from each call. When a channel parks later, one such stream
// is dropped so its shim reconnects and lands on the relay.
package delegation

import (
	"bytes"
	"encoding/json"
	"net"
	"os"
	"sync"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/paths"
)

const (
	// LocalMarker is the first line the local fallback sends: the shim
	// learns its stream reaches no Bromure AC (whatever it held there was
	// never done, and is safe to send again once a relay is back).
	LocalMarker = "bromure-local"
	// RelayGrace is how long a call on the local fallback waits for a relay
	// to park (a link redialling after a drop) before it's refused.
	RelayGrace = 20 * time.Second
)

// The texts differ from the Swift only in "this Mac" → "this machine".
const (
	notConnectedText = "No Bromure AC is connected to this machine right now, so other agents can't be reached. Delegation works while Bromure Agentic Coding has this machine's window open — tell your user."
	reconnectingText = "The link to Bromure AC dropped and hasn't come back yet (it usually does within a minute) — wait a moment and retry. If it keeps failing, Bromure AC may have closed: tell your user."
)

// Take is a parked channel's offer: it takes a stream (true, it owns it
// from then on) or declines it (false: its channel died while parked). A
// nil stream means the offer was pruned by a later park (its alive said
// no); it must decline, which releases its waiter.
type Take func(stream Stream) bool

type offer struct {
	take  Take
	alive func() bool
}

// Hub is the delegation.sock listener and the parked offers.
type Hub struct {
	path string
	// Grace is RelayGrace (tests shorten it).
	Grace time.Duration

	mu         sync.Mutex
	offers     []offer // newest last
	fb         fallbacks
	everParked bool
	ln         net.Listener
}

// NewHub makes a hub for socketPath ("" = paths.DelegationSocket()).
func NewHub(socketPath string) *Hub {
	if socketPath == "" {
		socketPath = paths.DelegationSocket()
	}
	return &Hub{path: socketPath, Grace: RelayGrace}
}

// SocketPath is where the hub listens.
func (h *Hub) SocketPath() string { return h.path }

// Park parks an offer. alive, when the parker can say, lets a later park
// drop the dead ones beneath it: handing out goes newest first, so an old
// dead one would never be reached, and its waiter would stay for ever.
func (h *Hub) Park(take Take, alive func() bool) {
	h.mu.Lock()
	var dead []Take
	kept := h.offers[:0]
	for _, o := range h.offers {
		if o.alive != nil && !o.alive() {
			dead = append(dead, o.take)
			continue
		}
		kept = append(kept, o)
	}
	h.offers = kept
	wasEmpty := len(h.offers) == 0
	first := !h.everParked
	h.everParked = true
	h.offers = append(h.offers, offer{take, alive})
	kick := h.fb.kick()
	h.mu.Unlock()
	if first {
		logx.Printf("delegation: a Bromure AC relay is parked")
	} else if wasEmpty && kick != nil {
		logx.Printf("delegation: a Bromure AC relay is back")
	}
	for _, d := range dead {
		_ = d(nil)
	}
	// Its shim reconnects at once, onto the channel just parked. A write
	// half-close, not a close: what was already sent on it still arrives.
	if kick != nil {
		_ = kick.CloseWrite()
	}
}

// ParkedCount is the offers waiting (tests, status).
func (h *Hub) ParkedCount() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.offers)
}

// HadRelay: a Bromure AC has parked here since this hub started (a stream
// answered locally then is a relay gap, not "no Bromure AC at all").
func (h *Hub) HadRelay() bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.everParked
}

// relay hands s to a live parked channel; false when there is none.
func (h *Hub) relay(s Stream) bool {
	for {
		h.mu.Lock()
		n := len(h.offers)
		if n == 0 {
			h.mu.Unlock()
			return false
		}
		o := h.offers[n-1]
		h.offers = h.offers[:n-1]
		h.mu.Unlock()
		if o.take(s) {
			return true
		}
	}
}

// waitForRelay: whether a relay parks for stream s within grace (kicked by
// a park, first in line among the streams holding a call). Another
// stream's offer isn't this one's: it waits on, keeping its place.
func (h *Hub) waitForRelay(s *Watched, grace time.Duration) bool {
	h.mu.Lock()
	h.fb.hold(s)
	h.mu.Unlock()
	defer func() {
		h.mu.Lock()
		h.fb.release(s)
		h.mu.Unlock()
	}()
	picked := func() bool {
		h.mu.Lock()
		defer h.mu.Unlock()
		return h.fb.kicked(s)
	}
	deadline := time.Now().Add(grace)
	for time.Now().Before(deadline) {
		if picked() {
			return true
		}
		// Its shim hung up: out of line, or a park would spend its one
		// offer on a stream that never reconnects.
		if s.PeerClosed() {
			return true
		}
		time.Sleep(250 * time.Millisecond)
	}
	return picked()
}

// Start listens on the socket and serves streams until Close.
func (h *Hub) Start() error {
	_ = os.Remove(h.path)
	ln, err := net.Listen("unix", h.path)
	if err != nil {
		return err
	}
	// Owner-only (Windows: the data dir's DACL is inherited; this is
	// best effort on a socket file).
	_ = paths.ProtectFile(h.path)
	h.mu.Lock()
	h.ln = ln
	h.mu.Unlock()
	go h.acceptLoop(ln)
	logx.Printf("delegation: listening on %s", h.path)
	return nil
}

// Close stops listening (streams already handed out are their owners').
func (h *Hub) Close() error {
	h.mu.Lock()
	ln := h.ln
	h.ln = nil
	h.mu.Unlock()
	if ln == nil {
		return nil
	}
	err := ln.Close()
	_ = os.Remove(h.path)
	return err
}

func (h *Hub) acceptLoop(ln net.Listener) {
	for {
		c, err := ln.Accept()
		if err != nil {
			if ne, ok := err.(net.Error); ok && ne.Timeout() {
				continue
			}
			return
		}
		s := Watch(c)
		if h.relay(s) {
			continue // the parked channel owns it now
		}
		h.mu.Lock()
		h.fb.add(s)
		h.mu.Unlock()
		go func() {
			h.serveLocally(s)
			h.mu.Lock()
			h.fb.remove(s)
			h.mu.Unlock()
			_ = s.Close()
		}()
	}
}

// serveLocally answers a stream here: enough MCP for the agent to know the
// tools, and a clear refusal from every call.
func (h *Hub) serveLocally(s *Watched) {
	if _, err := writeAll(s, []byte(LocalMarker+"\n")); err != nil {
		return
	}
	buf := make([]byte, 64<<10)
	var pending []byte
	sawHello := false
	for {
		n, err := s.Read(buf)
		if n > 0 {
			pending = append(pending, buf[:n]...)
		}
		for {
			nl := bytes.IndexByte(pending, '\n')
			if nl < 0 {
				break
			}
			line := append([]byte(nil), pending[:nl]...)
			pending = pending[nl+1:]
			if !sawHello { // bromure-hello w<N>
				sawHello = true
				continue
			}
			var msg map[string]json.RawMessage
			if json.Unmarshal(line, &msg) != nil || msg == nil {
				continue
			}
			_, hasID := msg["id"]
			// A call: a relay may be on its way back (a link redialling):
			// hold it, and if one parks, end this stream unanswered; the
			// shim sends it again over the relay (nothing here did it).
			if methodOf(msg) == "tools/call" && hasID {
				logx.Printf("delegation: a call with no Bromure AC relay — holding it up to %d s", int(h.Grace/time.Second))
				if h.waitForRelay(s, h.Grace) {
					logx.Printf("delegation: relay back — the call goes to it")
					return
				}
				logx.Printf("delegation: no relay after %d s — refused", int(h.Grace/time.Second))
			}
			reply := h.answer(msg)
			if reply == nil {
				continue
			}
			if _, err := writeAll(s, append(reply, '\n')); err != nil {
				return
			}
		}
		if err != nil {
			return
		}
	}
}

func methodOf(msg map[string]json.RawMessage) string {
	var m string
	if raw, ok := msg["method"]; ok {
		_ = json.Unmarshal(raw, &m)
	}
	return m
}

// answer is the local fallback's reply to one message (nil: a notification).
func (h *Hub) answer(msg map[string]json.RawMessage) []byte {
	id, ok := msg["id"]
	if !ok {
		return nil
	}
	type kv = orderedField
	result := func(r any) []byte {
		return encodeOrdered([]kv{{"jsonrpc", "2.0"}, {"id", id}, {"result", r}})
	}
	switch methodOf(msg) {
	case "initialize":
		return result(ordered{
			{"protocolVersion", "2025-03-26"},
			{"serverInfo", ordered{{"name", "bromure-delegation"}, {"version", "1.1.0"}}},
			{"capabilities", ordered{{"tools", ordered{{"listChanged", false}}}}},
			{"instructions", Instructions()},
		})
	case "ping":
		return result(ordered{})
	case "tools/list":
		return result(ordered{{"tools", Tools()}})
	case "tools/call":
		text := notConnectedText
		if h.HadRelay() {
			text = reconnectingText
		}
		return result(ordered{
			{"content", []any{ordered{{"type", "text"}, {"text", text}}}},
			{"isError", true},
		})
	default:
		return encodeOrdered([]kv{{"jsonrpc", "2.0"}, {"id", id},
			{"error", ordered{{"code", -32601}, {"message", "Method not found"}}}})
	}
}
