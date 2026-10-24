// Package devicechannel is the persistent outbound signaling WebSocket
// (`wss://…/v1/device-channel`), ported from
// Sources/AgentCoding/P2P/DeviceChannel.swift: presence plus grant-bound
// signaling frames both ways, our own ping with a pong deadline (a
// half-open socket never answers), capped jittered reconnect backoff, a
// terminal stop on a 401/403 upgrade (the token is revoked), and coalesced
// keys-changed notifications (the Swift's `.bromureAccountKeysChanged`).
//
// Callbacks run one at a time on a dispatcher goroutine (the Swift's main
// queue), in arrival order.
package devicechannel

import (
	"context"
	"errors"
	"math"
	"math/rand"
	"net/http"
	"sync"
	"time"

	"github.com/coder/websocket"

	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/p2p/signal"
)

// Channel is one device channel.
type Channel struct {
	url   string
	token string

	// HTTPClient is the upgrade's client (nil = default).
	HTTPClient *http.Client

	OnSignal            func(f signal.IncomingFrame)
	OnConnectionOffered func(g signal.ConnectionGrant)
	OnError             func(code, connectionID string)
	OnStateChange       func(connected bool)
	OnRevoked           func()
	OnKeysChanged       func()
	OnRecovered         func(downFor time.Duration)

	PingInterval    time.Duration // 25 s
	PongTimeout     time.Duration // 15 s
	RecycleMinAge   time.Duration // 30 s
	OutageThreshold time.Duration // 5 s
	KeysCoalesce    time.Duration // 2 s

	mu             sync.Mutex
	desiredOpen    bool
	connected      bool
	cur            *sock
	attempt        int
	openedAt       time.Time
	downSince      time.Time
	gen            uint64
	keysCoalescing bool
	nextID         uint64

	events chan func()
}

type sock struct {
	id     uint64
	conn   *websocket.Conn // nil until the upgrade completes
	ctx    context.Context
	cancel context.CancelFunc
}

// New is a channel to wsURL (controlplane.Endpoint.DeviceChannelURL)
// authenticated with the device token.
func New(wsURL, token string) *Channel {
	c := &Channel{url: wsURL, token: token,
		PingInterval: 25 * time.Second, PongTimeout: 15 * time.Second,
		RecycleMinAge: 30 * time.Second, OutageThreshold: 5 * time.Second, KeysCoalesce: 2 * time.Second,
		events: make(chan func(), 512)}
	go func() {
		for f := range c.events {
			f()
		}
	}()
	return c
}

func (c *Channel) dispatch(f func()) {
	select {
	case c.events <- f:
	default:
		go func() { c.events <- f }()
	}
}

// Connect starts holding the channel open.
func (c *Channel) Connect() {
	c.mu.Lock()
	if c.desiredOpen {
		c.mu.Unlock()
		return
	}
	c.desiredOpen = true
	c.mu.Unlock()
	c.openSocket(false)
}

// Close stops for good (until Connect).
func (c *Channel) Close() {
	c.mu.Lock()
	c.desiredOpen = false
	s := c.cur
	c.cur = nil
	c.mu.Unlock()
	if s != nil {
		s.close(websocket.StatusGoingAway)
	}
	c.setConnected(false)
}

func (s *sock) close(code websocket.StatusCode) {
	if s.conn != nil {
		go s.conn.Close(code, "")
		time.AfterFunc(2*time.Second, func() { s.conn.CloseNow() })
	}
	s.cancel()
}

// Connected reports whether the socket is open.
func (c *Channel) Connected() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.connected
}

// WaitConnected polls until connected or timeout.
func (c *Channel) WaitConnected(timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for !c.Connected() && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	return c.Connected()
}

// Recycle drops the socket and opens a fresh one now: it reads connected
// but signaling went unanswered. force: the network path changed, so even
// a young socket is bound to a route that's gone.
func (c *Channel) Recycle(force bool) {
	c.mu.Lock()
	s := c.cur
	want := c.desiredOpen
	young := !c.openedAt.IsZero() && time.Since(c.openedAt) < c.RecycleMinAge
	c.mu.Unlock()
	if !want || s == nil || (!force && young) {
		return
	}
	logx.Printf("p2p: device channel recycled")
	c.handleDrop(s, true, 0)
}

// ReconnectNow skips a pending backoff (the network changed). No-op while
// connected.
func (c *Channel) ReconnectNow() {
	c.mu.Lock()
	if !c.desiredOpen || c.connected {
		c.mu.Unlock()
		return
	}
	stale := c.cur
	c.cur = nil
	c.gen++
	if c.downSince.IsZero() {
		c.downSince = time.Now()
	}
	c.mu.Unlock()
	if stale != nil {
		stale.close(websocket.StatusGoingAway)
	}
	logx.Printf("p2p: network changed — device channel reconnecting now")
	c.openSocket(false)
}

// ErrNotConnected: no open socket to send on.
var ErrNotConnected = errors.New("device channel not connected")

// Send sends one signaling frame.
func (c *Channel) Send(ctx context.Context, f signal.OutgoingFrame) error {
	data, err := f.Encode()
	if err != nil {
		return err
	}
	c.mu.Lock()
	var conn *websocket.Conn
	if c.cur != nil {
		conn = c.cur.conn
	}
	c.mu.Unlock()
	if conn == nil {
		return ErrNotConnected
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	return conn.Write(ctx, websocket.MessageText, data)
}

// openSocket starts one connection attempt, unless one is current
// (onlyIfIdle) — the backoff timer and ReconnectNow never both open one.
func (c *Channel) openSocket(onlyIfIdle bool) {
	c.mu.Lock()
	if onlyIfIdle && c.cur != nil {
		c.mu.Unlock()
		return
	}
	c.nextID++
	ctx, cancel := context.WithCancel(context.Background())
	s := &sock{id: c.nextID, ctx: ctx, cancel: cancel}
	c.cur = s
	c.mu.Unlock()
	go c.run(s)
}

func (c *Channel) run(s *sock) {
	dctx, dcancel := context.WithTimeout(s.ctx, 30*time.Second)
	conn, resp, err := websocket.Dial(dctx, c.url, &websocket.DialOptions{
		HTTPClient: c.HTTPClient,
		HTTPHeader: http.Header{"Authorization": {"Bearer " + c.token}},
	})
	dcancel()
	if err != nil {
		status := 0
		if resp != nil {
			status = resp.StatusCode
		}
		c.handleDrop(s, false, status)
		return
	}
	conn.SetReadLimit(1 << 20)
	c.mu.Lock()
	current := c.cur == s
	if current {
		s.conn = conn
		c.openedAt = time.Now()
	}
	c.mu.Unlock()
	if !current {
		conn.CloseNow()
		return
	}
	c.setConnected(true)
	go c.heartbeat(s)
	for {
		typ, data, err := conn.Read(s.ctx)
		if err != nil {
			c.handleDrop(s, false, 0)
			return
		}
		if typ == websocket.MessageText || typ == websocket.MessageBinary {
			c.handle(data)
		}
	}
}

func (c *Channel) handle(data []byte) {
	f, ok := signal.DecodeIncoming(data)
	if !ok {
		return
	}
	switch f.Type {
	case signal.FrameSignal:
		if cb := c.OnSignal; cb != nil {
			c.dispatch(func() { cb(f) })
		}
	case signal.FrameConnection:
		if cb := c.OnConnectionOffered; cb != nil {
			c.dispatch(func() { cb(f.Grant) })
		}
	case signal.FrameError:
		if cb := c.OnError; cb != nil {
			c.dispatch(func() { cb(f.ErrorCode, f.ConnectionID) })
		}
	case signal.FrameKeysChanged:
		c.coalesceKeysChanged()
	}
}

// coalesceKeysChanged folds a burst into one OnKeysChanged per window: the
// listener re-pulls the whole key set anyway.
func (c *Channel) coalesceKeysChanged() {
	c.mu.Lock()
	if c.keysCoalescing {
		c.mu.Unlock()
		return
	}
	c.keysCoalescing = true
	c.mu.Unlock()
	time.AfterFunc(c.KeysCoalesce, func() {
		c.mu.Lock()
		c.keysCoalescing = false
		c.mu.Unlock()
		if cb := c.OnKeysChanged; cb != nil {
			c.dispatch(cb)
		}
	})
}

func (c *Channel) handleDrop(s *sock, immediate bool, status int) {
	c.mu.Lock()
	current := c.cur == s
	want := c.desiredOpen
	if current {
		c.cur = nil
		if want && c.downSince.IsZero() {
			c.downSince = time.Now()
		}
	}
	c.mu.Unlock()
	if !current {
		return
	}
	s.close(websocket.StatusGoingAway)
	c.setConnected(false)
	if status == 401 || status == 403 {
		c.mu.Lock()
		c.desiredOpen = false
		c.mu.Unlock()
		if cb := c.OnRevoked; cb != nil {
			c.dispatch(cb)
		}
		return
	}
	if want {
		c.scheduleReconnect(immediate)
	}
}

// Backoff is the reconnect delay before jitter: 0.5 s doubling, capped 30 s.
func Backoff(attempt int) time.Duration {
	if attempt > 6 {
		attempt = 6
	}
	secs := math.Min(30, 0.5*math.Pow(2, float64(attempt)))
	return time.Duration(secs * float64(time.Second))
}

func (c *Channel) scheduleReconnect(immediate bool) {
	c.mu.Lock()
	c.attempt++
	a := c.attempt
	if immediate {
		a = 0
	}
	g := c.gen
	c.mu.Unlock()
	delay := time.Duration(float64(Backoff(a)) * (0.75 + rand.Float64()*0.5))
	time.AfterFunc(delay, func() {
		c.mu.Lock()
		ok := c.desiredOpen && c.gen == g && c.cur == nil
		c.mu.Unlock()
		if ok {
			c.openSocket(true)
		}
	})
}

func (c *Channel) heartbeat(s *sock) {
	t := time.NewTicker(c.PingInterval)
	defer t.Stop()
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-t.C:
		}
		c.mu.Lock()
		conn := s.conn
		c.mu.Unlock()
		if conn == nil {
			return
		}
		ctx, cancel := context.WithTimeout(s.ctx, c.PongTimeout)
		err := conn.Ping(ctx)
		cancel()
		if err != nil {
			if s.ctx.Err() == nil {
				logx.Printf("p2p: device channel ping unanswered for %d s — reconnecting", int(c.PongTimeout.Seconds()))
			}
			c.handleDrop(s, false, 0)
			return
		}
	}
}

func (c *Channel) setConnected(v bool) {
	c.mu.Lock()
	changed := c.connected != v
	c.connected = v
	var recovered time.Duration
	if v {
		c.attempt = 0
		if !c.downSince.IsZero() {
			if d := time.Since(c.downSince); d >= c.OutageThreshold {
				recovered = d
			}
		}
		c.downSince = time.Time{}
	}
	c.mu.Unlock()
	if changed {
		if cb := c.OnStateChange; cb != nil {
			c.dispatch(func() { cb(v) })
		}
	}
	if recovered > 0 {
		logx.Printf("p2p: device channel back after %d s down", int(recovered.Seconds()))
		if cb := c.OnRecovered; cb != nil {
			c.dispatch(func() { cb(recovered) })
		}
	}
}
