// ws-relay listener — Go port of Sources/AgentCoding/P2P/WSRelay.swift.
//
// A browser (the hosted web client at bromure.io/client) can't open TCP or
// speak TURN, so it reaches a server through bromure.io's WebSocket byte relay:
// it takes a grant, sends an `offer` whose payload note is "ws-relay", and joins
// /v1/connections/<id>/relay as the dialer. On that offer this listener joins
// the same relay as the server party and splices it to the local sshd. The
// relay only pipes opaque bytes — SSH stays end to end. The relay authorizes
// the join itself (only the grant's server install may join as listener).

package p2p

import (
	"context"
	"net"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/coder/websocket"

	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/p2p/controlplane"
)

// WSRelayNote is the offer note a ws-relay dialer sends.
const WSRelayNote = "ws-relay"

// wsRelayMax bounds concurrent relayed SSH sessions.
const wsRelayMax = 8

var (
	wsRelayMu   sync.Mutex
	wsRelayLive = map[string]bool{}
)

// validConnID: a grant id is a UUID-like token; anything else never reaches a URL.
func validConnID(id string) bool {
	if id == "" || len(id) > 128 {
		return false
	}
	for _, c := range id {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}

// RelayURL is wss://…/v1/connections/<id>/relay (ws:// for an http base).
func relayURL(ep controlplane.Endpoint, connID string) string {
	u := ep.URL("/v1/connections/" + connID + "/relay")
	if ep.Base.Scheme == "http" {
		return "ws" + u[len("http"):]
	}
	return "wss" + u[len("https"):]
}

// joinWSRelay joins the relay for connID and splices it to 127.0.0.1:sshPort.
// Idempotent per connection; returns at once (the splice runs in goroutines).
func joinWSRelay(ep controlplane.Endpoint, bearer, connID string, sshPort int, hc *http.Client) {
	if !validConnID(connID) {
		logx.Printf("ws-relay: refusing malformed connection id")
		return
	}
	wsRelayMu.Lock()
	if wsRelayLive[connID] || len(wsRelayLive) >= wsRelayMax {
		wsRelayMu.Unlock()
		return
	}
	wsRelayLive[connID] = true
	wsRelayMu.Unlock()
	go func() {
		defer func() { wsRelayMu.Lock(); delete(wsRelayLive, connID); wsRelayMu.Unlock() }()
		ssh, err := net.DialTimeout("tcp", "127.0.0.1:"+strconv.Itoa(sshPort), 5*time.Second)
		if err != nil {
			logx.Printf("ws-relay: local sshd :%d unreachable: %v", sshPort, err)
			return
		}
		defer ssh.Close()
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		dctx, dcancel := context.WithTimeout(ctx, 30*time.Second)
		ws, _, err := websocket.Dial(dctx, relayURL(ep, connID), &websocket.DialOptions{
			HTTPClient: hc,
			HTTPHeader: http.Header{"Authorization": []string{"Bearer " + bearer}},
		})
		dcancel()
		if err != nil {
			logx.Printf("ws-relay: join %s failed: %v", connID, err)
			return
		}
		ws.SetReadLimit(4 << 20)
		defer ws.Close(websocket.StatusNormalClosure, "")
		logx.Printf("ws-relay: joined %s", connID)
		done := make(chan struct{}, 2)
		go func() { // relay → sshd
			defer func() { done <- struct{}{} }()
			for {
				typ, data, err := ws.Read(ctx)
				if err != nil || typ != websocket.MessageBinary {
					return
				}
				if _, err := ssh.Write(data); err != nil {
					return
				}
			}
		}()
		go func() { // sshd → relay
			defer func() { done <- struct{}{} }()
			buf := make([]byte, 32*1024)
			for {
				n, err := ssh.Read(buf)
				if n > 0 {
					if werr := ws.Write(ctx, websocket.MessageBinary, buf[:n]); werr != nil {
						return
					}
				}
				if err != nil {
					return
				}
			}
		}()
		<-done
		logx.Printf("ws-relay: %s closed", connID)
	}()
}
