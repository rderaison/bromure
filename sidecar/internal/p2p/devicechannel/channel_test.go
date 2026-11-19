package devicechannel

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/rderaison/bromure/sidecar/internal/p2p/signal"
)

type fakeGW struct {
	mu      sync.Mutex
	conns   []*websocket.Conn
	frames  []string
	revoked atomic.Bool
	accepts atomic.Int32
}

func (g *fakeGW) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("Authorization") != "Bearer tok" || g.revoked.Load() {
		http.Error(w, "no", 401)
		return
	}
	c, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	g.mu.Lock()
	g.conns = append(g.conns, c)
	g.mu.Unlock()
	g.accepts.Add(1)
	for {
		_, data, err := c.Read(context.Background())
		if err != nil {
			return
		}
		g.mu.Lock()
		g.frames = append(g.frames, string(data))
		g.mu.Unlock()
	}
}

func (g *fakeGW) last() *websocket.Conn {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.conns[len(g.conns)-1]
}

func wait(t *testing.T, what string, f func() bool) {
	t.Helper()
	for end := time.Now().Add(5 * time.Second); time.Now().Before(end); time.Sleep(10 * time.Millisecond) {
		if f() {
			return
		}
	}
	t.Fatalf("timeout: %s", what)
}

func TestChannel(t *testing.T) {
	gw := &fakeGW{}
	srv := httptest.NewServer(gw)
	defer srv.Close()
	c := New("ws"+strings.TrimPrefix(srv.URL, "http")+"/v1/device-channel", "tok")
	c.KeysCoalesce = 100 * time.Millisecond
	var keys atomic.Int32
	var sig, grant atomic.Value
	var revoked atomic.Bool
	c.OnKeysChanged = func() { keys.Add(1) }
	c.OnSignal = func(f signal.IncomingFrame) { sig.Store(f) }
	c.OnConnectionOffered = func(g signal.ConnectionGrant) { grant.Store(g) }
	c.OnRevoked = func() { revoked.Store(true) }
	c.Connect()
	if !c.WaitConnected(3 * time.Second) {
		t.Fatal("not connected")
	}
	err := c.Send(context.Background(), signal.OutgoingFrame{ConnectionID: "c1", Seq: 1, Kind: signal.KindOffer, Payload: signal.WithNote("connect")})
	if err != nil {
		t.Fatal(err)
	}
	wait(t, "frame", func() bool { gw.mu.Lock(); defer gw.mu.Unlock(); return len(gw.frames) == 1 })
	if gw.frames[0] != `{"connectionId":"c1","seq":1,"kind":"offer","payload":{"v":1,"note":"connect"}}` {
		t.Fatalf("sent %s", gw.frames[0])
	}
	conn := gw.last()
	ctx := context.Background()
	for i := 0; i < 50; i++ { // a storm folds into one callback
		conn.Write(ctx, websocket.MessageText, []byte(`{"type":"keys-changed"}`))
	}
	conn.Write(ctx, websocket.MessageText, []byte(`{"type":"signal","connectionId":"c1","seq":1,"kind":"answer","from":"s","payload":{"v":1,"candidates":[]}}`))
	conn.Write(ctx, websocket.MessageText, []byte(`{"type":"connection","connection":{"id":"c9","expiresAt":"x","self":{"deviceId":"a","signalId":"s","role":"server"},"peer":{"deviceId":"b","signalId":"t","role":"client"}}}`))
	wait(t, "signal+grant", func() bool { return sig.Load() != nil && grant.Load() != nil })
	time.Sleep(300 * time.Millisecond)
	if n := keys.Load(); n != 1 {
		t.Fatalf("keys-changed fired %d times", n)
	}
	// A dropped socket reconnects (backoff ~1 s).
	conn.CloseNow()
	wait(t, "reconnect", func() bool { return gw.accepts.Load() == 2 && c.Connected() })
	// A forced recycle opens a fresh one at once.
	c.Recycle(true)
	wait(t, "recycle", func() bool { return gw.accepts.Load() == 3 && c.Connected() })
	// A revoked token: 401 on the upgrade is terminal.
	gw.revoked.Store(true)
	gw.last().CloseNow()
	wait(t, "revoked", func() bool { return revoked.Load() })
	time.Sleep(1500 * time.Millisecond)
	if gw.accepts.Load() != 3 || c.Connected() {
		t.Fatal("kept reconnecting after a revoke")
	}
	c.Close()
}

func TestBackoff(t *testing.T) {
	want := []time.Duration{500 * time.Millisecond, time.Second, 2 * time.Second, 4 * time.Second,
		8 * time.Second, 16 * time.Second, 30 * time.Second, 30 * time.Second}
	for i, w := range want {
		if got := Backoff(i); got != w {
			t.Errorf("Backoff(%d) = %v want %v", i, got, w)
		}
	}
}

// A server that accepts and never reads: no pong comes back, so the pong
// deadline (not the ping) notices and the channel re-dials.
func TestPingDeadline(t *testing.T) {
	var accepts atomic.Int32
	hold := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		accepts.Add(1)
		<-hold
		c.CloseNow()
	}))
	defer srv.Close()
	defer close(hold)
	c := New("ws"+strings.TrimPrefix(srv.URL, "http"), "tok")
	c.PingInterval, c.PongTimeout = 100*time.Millisecond, 100*time.Millisecond
	c.Connect()
	defer c.Close()
	wait(t, "first", func() bool { return accepts.Load() >= 1 })
	wait(t, "re-dial after an unanswered ping", func() bool { return accepts.Load() >= 2 })
}
