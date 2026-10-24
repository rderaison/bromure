// Package p2p is the Sidecar's peer-to-peer engine, ported from
// Sources/AgentCoding/P2P/P2PBroker.swift: one device channel per identity,
// relay-only serving (an offer gets an empty answer, then the RFC 6062 TCP
// relay candidate; each relayed leg is spliced into the loopback SSH
// server), and the dialer that reaches an account server's SSH port.
//
// Where the Swift hands MachineLinker a loopback shim that re-dials the
// winning candidate per SSH connection, Dial returns the connection itself
// and caches the winner: later dials of the same peer reuse it (one grant,
// one relay allocation per peer, like the shim).
package p2p

import (
	"context"
	"errors"
	"net"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/p2p/controlplane"
	"github.com/rderaison/bromure/sidecar/internal/p2p/devicechannel"
	"github.com/rderaison/bromure/sidecar/internal/p2p/identity"
	"github.com/rderaison/bromure/sidecar/internal/p2p/netmon"
	"github.com/rderaison/bromure/sidecar/internal/p2p/signal"
	"github.com/rderaison/bromure/sidecar/internal/p2p/stun"
	"github.com/rderaison/bromure/sidecar/internal/p2p/turn"
)

// session is one in-flight grant (P2PSession): the strictly increasing
// outgoing seq and the peer's candidates.
type session struct {
	grant signal.ConnectionGrant

	mu       sync.Mutex
	outSeq   int
	received []signal.Candidate
	seen     map[string]bool
	sawPeer  bool
}

func newSession(g signal.ConnectionGrant) *session {
	return &session{grant: g, seen: map[string]bool{}}
}

func (s *session) receive(p signal.Payload) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sawPeer = true
	for _, c := range p.All() {
		if !s.seen[c.Key()] {
			s.seen[c.Key()] = true
			s.received = append(s.received, c)
		}
	}
}

func (s *session) candidates() []signal.Candidate {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]signal.Candidate(nil), s.received...)
}

func (s *session) gotPeerFrame() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.sawPeer
}

func (s *session) send(ctx context.Context, kind string, p signal.Payload, ch *devicechannel.Channel) error {
	s.mu.Lock()
	s.outSeq++
	seq := s.outSeq
	s.mu.Unlock()
	return ch.Send(ctx, signal.OutgoingFrame{ConnectionID: s.grant.ID, Seq: seq, Kind: kind, Payload: p})
}

type relayEntry struct {
	grantID  string
	listener *turn.Listener
}

type cachedWinner struct {
	cand signal.Candidate
	path Path
}

// Broker is the P2P engine for one identity source.
type Broker struct {
	// Identity resolves the current identity (identity.Current by default).
	Identity func() (identity.Identity, bool)
	// HTTP is the control-plane and device-channel client (nil = default).
	HTTP *http.Client
	// Admit filters the peer addresses a relay lets in (public unicast).
	Admit func(string) bool
	// OnKeysChanged runs when the channel reports a peer's key changed.
	OnKeysChanged func()
	// OnRevoked runs after the channel reported this device revoked.
	OnRevoked func()
	// OnPathChanged runs after peer paths were reset (network change).
	OnPathChanged func()

	mu            sync.Mutex
	channel       *devicechannel.Channel
	channelToken  string
	sessions      map[string]*session
	winners       map[string]cachedWinner
	establishing  map[string]chan struct{}
	relays        []relayEntry
	serving       bool
	sshPort       int
	relayHostRank []string
	pathGen       uint64
	lastPathReset time.Time
	monitor       *netmon.Monitor
	lastSig       string
}

// NewBroker is a relay-only broker (the Sidecar never listens publicly).
func NewBroker() *Broker {
	return &Broker{Identity: identity.Current, sessions: map[string]*session{},
		winners: map[string]cachedWinner{}, establishing: map[string]chan struct{}{}, sshPort: 2223}
}

// StunBudget is the dialer's whole STUN binding, DNS included.
const StunBudget = 6 * time.Second

// RelayRedials is how many more times a refused relay candidate is tried.
const RelayRedials = 4

func (b *Broker) client(id identity.Identity) (*controlplane.Client, error) {
	ep, err := controlplane.NewEndpoint(id.APIBase)
	if err != nil {
		return nil, err
	}
	c := controlplane.New(ep)
	if b.HTTP != nil {
		c.HTTP = b.HTTP
	}
	return c, nil
}

func (b *Broker) admit() func(string) bool {
	if b.Admit != nil {
		return b.Admit
	}
	return turn.IsPublicUnicast
}

// ensureChannel returns a connected channel for id, building it on first
// use or when the bearer changed; waits ≤5 s for it to open.
func (b *Broker) ensureChannel(id identity.Identity) *devicechannel.Channel {
	b.mu.Lock()
	if b.channel != nil && b.channelToken == id.Bearer {
		ch := b.channel
		b.mu.Unlock()
		if ch.WaitConnected(5 * time.Second) {
			return ch
		}
		return nil
	}
	old := b.channel
	ep, err := controlplane.NewEndpoint(id.APIBase)
	if err != nil {
		b.mu.Unlock()
		return nil
	}
	ch := devicechannel.New(ep.DeviceChannelURL(), id.Bearer)
	ch.HTTPClient = b.HTTP
	b.channel = ch
	b.channelToken = id.Bearer
	b.mu.Unlock()
	if old != nil {
		old.Close()
	}

	ch.OnSignal = func(f signal.IncomingFrame) {
		b.mu.Lock()
		s := b.sessions[f.ConnectionID]
		b.mu.Unlock()
		if s != nil {
			s.receive(f.Payload)
		}
	}
	ch.OnConnectionOffered = func(g signal.ConnectionGrant) { b.handleOffered(g) }
	ch.OnError = func(code, connID string) {
		if connID == "" {
			connID = "-"
		}
		logx.Printf("p2p: signaling error %s conn=%s", code, connID)
	}
	ch.OnRecovered = func(d time.Duration) { b.channelRecovered(d) }
	ch.OnKeysChanged = func() {
		logx.Printf("p2p: keys-changed — re-syncing authorized keys")
		if b.OnKeysChanged != nil {
			b.OnKeysChanged()
		}
	}
	revokedToken := id.Bearer
	ch.OnRevoked = func() {
		logx.Printf("p2p: device channel reported revoked")
		// Only the record THIS channel spoke for: a re-enrolled record
		// that replaced it must survive the old device's revocation.
		if rec, res := identity.Load(); res == identity.Found && rec.DeviceToken == revokedToken {
			identity.Erase()
		}
		b.StopServing()
		if b.OnRevoked != nil {
			b.OnRevoked()
		}
	}
	ch.Connect()
	if ch.WaitConnected(5 * time.Second) {
		return ch
	}
	return nil
}

func (b *Broker) currentChannel() *devicechannel.Channel {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.channel
}

// Serving reports whether StartServing is in effect.
func (b *Broker) Serving() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.serving
}

// ChannelConnected reports whether the device channel is up.
func (b *Broker) ChannelConnected() bool {
	ch := b.currentChannel()
	return ch != nil && ch.Connected()
}

// StartServing turns the control plane's p2p_server flag on and holds the
// device channel open (presence). Relay-only: no port mapping, no host
// candidates. Idempotent.
func (b *Broker) StartServing(sshPort int) {
	id, ok := b.Identity()
	if !ok {
		return
	}
	b.mu.Lock()
	was := b.serving
	b.serving = true
	b.sshPort = sshPort
	b.mu.Unlock()
	b.startNetworkMonitor()
	if was {
		return
	}
	go func() {
		if c, err := b.client(id); err == nil {
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			if _, err := c.SetServerMode(ctx, id.Bearer, true); err != nil {
				logx.Printf("p2p: server-mode on failed: %v", err)
			}
			cancel()
		}
		b.ensureChannel(id)
	}()
}

// StopServing clears p2p_server, drops the channel and every relay.
func (b *Broker) StopServing() {
	b.mu.Lock()
	was := b.serving
	b.serving = false
	ch := b.channel
	b.channel = nil
	b.channelToken = ""
	b.sessions = map[string]*session{}
	relays := b.relays
	b.relays = nil
	b.mu.Unlock()
	if ch != nil {
		ch.Close()
	}
	for _, r := range relays {
		r.listener.Stop()
	}
	if was {
		if id, ok := b.Identity(); ok {
			if c, err := b.client(id); err == nil {
				go func() {
					ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
					defer cancel()
					_, _ = c.SetServerMode(ctx, id.Bearer, false)
				}()
			}
		}
	}
}

func (b *Broker) reportComplete(c *controlplane.Client, id identity.Identity, connID string, r controlplane.ConnectionReport) {
	if !id.RecordsSessionTelemetry() {
		logx.Printf("p2p: personal account — session telemetry suppressed for %s", connID)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	_, _ = c.Complete(ctx, id.Bearer, connID, r)
}

// handleOffered answers a client's grant: an empty answer (relay-only),
// then the relay rung, then telemetry, then a grace for late frames.
func (b *Broker) handleOffered(g signal.ConnectionGrant) {
	id, ok := b.Identity()
	if !ok {
		return
	}
	c, err := b.client(id)
	if err != nil {
		return
	}
	s := newSession(g)
	b.mu.Lock()
	b.sessions[g.ID] = s
	port := b.sshPort
	ch := b.channel
	b.mu.Unlock()
	if ch == nil {
		return
	}
	go func() {
		ctx := context.Background()
		_ = s.send(ctx, signal.KindAnswer, signal.WithCandidates([]signal.Candidate{}), ch)
		b.standUpRelay(s, c, id, port, ch)
		b.reportComplete(c, id, g.ID, controlplane.Connected("direct", 0))
		time.Sleep(15 * time.Second)
		b.mu.Lock()
		if b.sessions[g.ID] == s {
			delete(b.sessions, g.ID)
		}
		b.mu.Unlock()
	}()
}

func srflxIPs(s *session) []string {
	var ips []string
	for _, c := range s.candidates() {
		if c.Kind == signal.KindSrflx && !containsStr(ips, c.IP) {
			ips = append(ips, c.IP)
		}
	}
	return ips
}

// standUpRelay: TURN creds, the dialer's srflx IPs (≤6 s, then 1.5 s grace
// for the others), allocate on the nearest relay, trickle the relay
// candidate, then hand late dialer addresses to the listener.
func (b *Broker) standUpRelay(s *session, c *controlplane.Client, id identity.Identity, sshPort int, ch *devicechannel.Channel) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	creds, err := c.TurnCredentials(ctx, id.Bearer, s.grant.ID)
	cancel()
	if err != nil {
		logx.Printf("p2p: turn-credentials unavailable — direct candidates only")
		return
	}
	deadline := time.Now().Add(6 * time.Second)
	for len(srflxIPs(s)) == 0 && time.Now().Before(deadline) {
		time.Sleep(150 * time.Millisecond)
	}
	if len(srflxIPs(s)) == 0 {
		logx.Printf("p2p: dialer sent no srflx — relay rung skipped")
		return
	}
	firstSrflx := time.Now()
	time.Sleep(1500 * time.Millisecond)
	permitIPs := srflxIPs(s)
	urls := b.orderedRelayURLs(creds.URLs)
	l, info, err := turn.StartListener(turn.Credentials{URLs: urls, Username: creds.Username, Credential: creds.Credential},
		permitIPs, sshPort, b.admit())
	if err != nil {
		return
	}
	b.register(l, s.grant.ID)
	_ = s.send(context.Background(), signal.KindCandidate, signal.WithCandidate(info.Relay), ch)

	handed := map[string]bool{}
	for _, ip := range permitIPs {
		handed[ip] = true
	}
	lateUntil := firstSrflx.Add(StunBudget + 2*time.Second)
	if t := time.Now().Add(2 * time.Second); t.After(lateUntil) {
		lateUntil = t
	}
	for {
		for _, ip := range srflxIPs(s) {
			if !handed[ip] {
				handed[ip] = true
				logx.Printf("p2p: dialer also seen from %s — letting it in", ip)
				l.Permit(ip)
			}
		}
		if !time.Now().Before(lateUntil) {
			break
		}
		time.Sleep(250 * time.Millisecond)
	}
}

func (b *Broker) register(l *turn.Listener, grantID string) {
	l.OnStopped = func() {
		b.mu.Lock()
		defer b.mu.Unlock()
		for i, r := range b.relays {
			if r.listener == l {
				b.relays = append(b.relays[:i], b.relays[i+1:]...)
				break
			}
		}
	}
	b.mu.Lock()
	b.relays = append(b.relays, relayEntry{grantID, l})
	var evicted []relayEntry
	if len(b.relays) > 6 {
		evicted = append(evicted, b.relays[0])
		b.relays = b.relays[1:]
	}
	b.mu.Unlock()
	for _, e := range evicted {
		short := e.grantID
		if len(short) > 8 {
			short = short[:8]
		}
		logx.Printf("p2p: relay session cap — dropping oldest (grant %s)", short)
		e.listener.Stop()
	}
}

// orderedRelayURLs ranks relays by RTT, cached per network path.
func (b *Broker) orderedRelayURLs(urls []string) []string {
	hosts := turn.DistinctHosts(urls)
	if len(hosts) <= 1 {
		return urls
	}
	b.mu.Lock()
	gen, cached := b.pathGen, b.relayHostRank
	b.mu.Unlock()
	if cached != nil && sameSet(cached, hosts) {
		return turn.Regroup(urls, cached)
	}
	ordered := turn.OrderURLsByRTT(urls, 3, time.Second)
	b.mu.Lock()
	if b.pathGen == gen {
		b.relayHostRank = turn.DistinctHosts(ordered)
	}
	b.mu.Unlock()
	return ordered
}

func sameSet(a, b []string) bool {
	x := append([]string(nil), a...)
	y := append([]string(nil), b...)
	sort.Strings(x)
	sort.Strings(y)
	return strings.Join(x, "\x00") == strings.Join(y, "\x00")
}

func containsStr(xs []string, s string) bool {
	for _, x := range xs {
		if x == s {
			return true
		}
	}
	return false
}

// ErrNotEnrolled: no bromure.io identity.
var ErrNotEnrolled = errors.New("p2p: not signed in to bromure.io")

// ErrUnreachable: no candidate connected.
var ErrUnreachable = errors.New("p2p: no viable path to the peer")

// Dial reaches peerDeviceID's SSH port: a fresh connection to the cached
// winning path, else one establish (single-flight per peer; concurrent
// callers wait for it and then dial its winner). ctx bounds the whole
// thing; without a deadline the Swift's 20 s applies.
func (b *Broker) Dial(ctx context.Context, peerDeviceID string) (net.Conn, error) {
	b.startNetworkMonitor()
	timeout := 20 * time.Second
	if dl, ok := ctx.Deadline(); ok {
		timeout = time.Until(dl)
	}
	if conn, ok := b.dialCached(peerDeviceID); ok {
		return conn, nil
	}
	for {
		b.mu.Lock()
		wait, busy := b.establishing[peerDeviceID]
		if !busy {
			done := make(chan struct{})
			b.establishing[peerDeviceID] = done
			b.mu.Unlock()
			conn, err := b.establish(ctx, peerDeviceID, timeout)
			b.mu.Lock()
			delete(b.establishing, peerDeviceID)
			b.mu.Unlock()
			close(done)
			return conn, err
		}
		b.mu.Unlock()
		select {
		case <-wait:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		if conn, ok := b.dialCached(peerDeviceID); ok {
			return conn, nil
		}
	}
}

func (b *Broker) dialCached(peer string) (net.Conn, bool) {
	b.mu.Lock()
	w, ok := b.winners[peer]
	b.mu.Unlock()
	if !ok {
		return nil, false
	}
	conn, err := ConnectCandidate(w.cand, 5*time.Second)
	if err != nil {
		// The Swift shim just fails the connection and MachineLinker drops
		// the path after two failures; here one failure re-establishes.
		logx.Printf("p2p: cached path to %s (%s:%d) failed — re-establishing", short(peer), w.cand.IP, w.cand.Port)
		b.ClosePeer(peer)
		return nil, false
	}
	return conn, true
}

func short(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}

// ClosePeer forgets a peer's cached path.
func (b *Broker) ClosePeer(peer string) {
	b.mu.Lock()
	delete(b.winners, peer)
	b.mu.Unlock()
}

// CachedPath is the path a peer's dials take, if one is cached.
func (b *Broker) CachedPath(peer string) (Path, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	w, ok := b.winners[peer]
	return w.path, ok
}

func (b *Broker) establish(ctx context.Context, peer string, timeout time.Duration) (net.Conn, error) {
	id, ok := b.Identity()
	if !ok {
		return nil, ErrNotEnrolled
	}
	c, err := b.client(id)
	if err != nil {
		return nil, err
	}
	ch := b.ensureChannel(id)
	if ch == nil {
		return nil, errors.New("p2p: device channel won't open")
	}
	rctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	grant, err := c.RequestConnection(rctx, id.Bearer, peer)
	cancel()
	if err != nil {
		logx.Printf("p2p: connection request failed: %v", err)
		return nil, err
	}
	s := newSession(grant)
	b.mu.Lock()
	b.sessions[grant.ID] = s
	b.mu.Unlock()
	defer func() {
		b.mu.Lock()
		if b.sessions[grant.ID] == s {
			delete(b.sessions, grant.ID)
		}
		b.mu.Unlock()
	}()

	if err := s.send(ctx, signal.KindOffer, signal.WithNote("connect"), ch); err != nil {
		logx.Printf("p2p: offer send failed: %v", err)
		ch.Recycle(false)
		b.reportComplete(c, id, grant.ID, controlplane.Failed("signaling"))
		return nil, err
	}

	go b.trickleSrflx(s, c, id, ch)

	t0 := time.Now()
	deadline := time.Now().Add(timeout)
	tried := map[string]bool{}
	type relayTry struct {
		count int
		last  time.Time
		cand  signal.Candidate
	}
	relayTries := map[string]*relayTry{}
	var w *win
	for w == nil && time.Now().Before(deadline) {
		if ctx.Err() != nil {
			break
		}
		var fresh []signal.Candidate
		for _, cand := range s.candidates() {
			if !tried[cand.Key()] {
				fresh = append(fresh, cand)
			}
		}
		if len(fresh) == 0 {
			for _, rt := range relayTries {
				if rt.count < RelayRedials+1 && time.Since(rt.last) >= 2*time.Second {
					fresh = append(fresh, rt.cand)
				}
			}
		}
		if len(fresh) == 0 {
			time.Sleep(50 * time.Millisecond)
			continue
		}
		var desc []string
		for _, cand := range fresh {
			tried[cand.Key()] = true
			if cand.Kind == signal.KindRelay {
				rt := relayTries[cand.Key()]
				if rt == nil {
					rt = &relayTry{cand: cand}
					relayTries[cand.Key()] = rt
				}
				rt.count++
				rt.last = time.Now()
			}
			desc = append(desc, cand.Kind+" "+stun.HostPort(cand.IP, cand.Port)+" prio="+strconv.Itoa(cand.Prio))
		}
		logx.Printf("p2p: peer candidates: %s", strings.Join(desc, " | "))
		batchDeadline := time.Now().Add(4500 * time.Millisecond)
		if batchDeadline.After(deadline) {
			batchDeadline = deadline
		}
		w = dialCandidates(fresh, time.Second, batchDeadline)
	}
	if w == nil {
		stage := "signaling"
		if s.gotPeerFrame() {
			stage = "ice"
		}
		logx.Printf("p2p: no viable path to %s (%d candidates tried)", short(peer), len(tried))
		if stage == "signaling" {
			ch.Recycle(false)
		}
		b.reportComplete(c, id, grant.ID, controlplane.Failed(stage))
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, ErrUnreachable
	}
	b.mu.Lock()
	b.winners[peer] = cachedWinner{w.cand, w.path}
	b.mu.Unlock()
	ms := int(time.Since(t0) / time.Millisecond)
	b.reportComplete(c, id, grant.ID, controlplane.Connected(w.path.ReportKind(), ms))
	logx.Printf("p2p: peer %s path=%s via %s", short(peer), w.path.Label(), stun.HostPort(w.cand.IP, w.cand.Port))
	return w.conn, nil
}

// trickleSrflx mints the grant's TURN credentials, asks every relay
// (nearest first) for our public address, and trickles each new one as a
// srflx candidate: the listener's relay permission must cover it.
func (b *Broker) trickleSrflx(s *session, c *controlplane.Client, id identity.Identity, ch *devicechannel.Channel) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	creds, err := c.TurnCredentials(ctx, id.Bearer, s.grant.ID)
	cancel()
	if err != nil {
		logx.Printf("p2p: turn-credentials unavailable — dialing direct only")
		return
	}
	logx.Printf("p2p: turn relays advertised: %s", strings.Join(creds.URLs, ", "))
	urls := b.orderedRelayURLs(creds.URLs)
	stuns := turn.StunEndpointsPerHost(urls)
	if len(stuns) == 0 {
		return
	}
	type res struct {
		host string
		ip   string
		port int
		ok   bool
	}
	out := make(chan res, len(stuns))
	for _, st := range stuns {
		go func(st turn.HostPort) {
			done := make(chan res, 1)
			go func() {
				ip, port, ok := turn.PublicAddress(st.Host, st.Port, 4*time.Second)
				done <- res{st.Host, ip, port, ok}
			}()
			select {
			case r := <-done:
				out <- r
			case <-time.After(StunBudget):
				out <- res{host: st.Host}
			}
		}(st)
	}
	sent := map[string]bool{}
	for range stuns {
		r := <-out
		if !r.ok {
			logx.Printf("p2p: STUN binding to %s failed", r.host)
			continue
		}
		if sent[r.ip] {
			continue
		}
		logx.Printf("p2p: our public address (via %s) is %s", r.host, stun.HostPort(r.ip, r.port))
		cand := signal.NewCandidate(signal.KindSrflx, signal.ProtoTCP, r.ip, r.port, nil)
		if err := s.send(context.Background(), signal.KindCandidate, signal.WithCandidate(cand), ch); err != nil {
			logx.Printf("p2p: sending our address %s failed: %v", r.ip, err)
			continue
		}
		sent[r.ip] = true
	}
}

// ResetPeerPaths drops every cached peer path and the relay ranking.
func (b *Broker) ResetPeerPaths() {
	b.mu.Lock()
	n := len(b.winners)
	b.winners = map[string]cachedWinner{}
	b.relayHostRank = nil
	b.pathGen++
	b.lastPathReset = time.Now()
	b.mu.Unlock()
	if n > 0 {
		logx.Printf("p2p: network changed — dropped %d peer path(s) to re-establish", n)
	}
}

func (b *Broker) channelRecovered(d time.Duration) {
	b.mu.Lock()
	recent := time.Since(b.lastPathReset) < 15*time.Second
	peers := len(b.winners)
	b.mu.Unlock()
	if recent {
		return
	}
	logx.Printf("p2p: signaling back after %d s — re-establishing %d peer path(s)", int(d.Seconds()), peers)
	b.ResetPeerPaths()
	if b.OnPathChanged != nil {
		b.OnPathChanged()
	}
}

// startNetworkMonitor watches the network for the process lifetime.
func (b *Broker) startNetworkMonitor() {
	b.mu.Lock()
	if b.monitor != nil {
		b.mu.Unlock()
		return
	}
	m := &netmon.Monitor{Handler: b.handlePathUpdate}
	b.monitor = m
	b.mu.Unlock()
	m.Start()
}

// handlePathUpdate reacts like the Swift's NWPathMonitor handler: any
// usable update retries a down channel now; a changed signature (after the
// baseline) resets peer paths and recycles the channel.
func (b *Broker) handlePathUpdate(u netmon.Update) {
	b.mu.Lock()
	changed := u.Signature != b.lastSig
	hadBaseline := b.lastSig != ""
	b.lastSig = u.Signature
	ch := b.channel
	b.mu.Unlock()
	if !u.Usable {
		return
	}
	if ch != nil {
		ch.ReconnectNow()
	}
	if !changed || !hadBaseline {
		return
	}
	logx.Printf("p2p: network path changed (%s) — re-establishing", u.Signature)
	b.ResetPeerPaths()
	if ch != nil {
		ch.Recycle(true)
	}
	if b.OnPathChanged != nil {
		b.OnPathChanged()
	}
}

// Close stops serving and the network monitor.
func (b *Broker) Close() {
	b.StopServing()
	b.mu.Lock()
	m := b.monitor
	b.monitor = nil
	b.mu.Unlock()
	if m != nil {
		m.Stop()
	}
}
