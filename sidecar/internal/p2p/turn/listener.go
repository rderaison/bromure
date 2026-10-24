package turn

import (
	"errors"
	"fmt"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/p2p/signal"
	"github.com/rderaison/bromure/sidecar/internal/p2p/sockopt"
	"github.com/rderaison/bromure/sidecar/internal/p2p/stun"
)

// IdleReapAfter: an allocation with no spliced leg this long is an orphan.
var IdleReapAfter = 180 * time.Second

// Started is what a listener advertises.
type Started struct {
	Relay    signal.Candidate // the relayed transport address (`relay` candidate)
	MappedIP string           // our public IP as the relay saw the control leg
}

// Listener is the serving side's whole TURN life (TurnRelayListener): one
// RFC 6062 TCP allocation, permissions for the dialer, and a service loop
// that answers each ConnectionAttempt with a ConnectionBind on a new data
// connection spliced into 127.0.0.1:<sshPort>.
type Listener struct {
	client   *Client
	sshPort  int
	lifetime uint32

	mu         sync.Mutex
	permits    *RelayPermits
	stopped    bool
	activeLegs int
	idleSince  time.Time

	// OnStopped runs once when the service loop exits for any reason.
	OnStopped func()
}

// Credentials is the TURN REST pair plus the relay urls (nearest first).
type Credentials struct {
	URLs       []string
	Username   string
	Credential string
}

// StartListener connects, allocates and installs the dialer's permissions
// (blocking, ≤ ~10 s), then starts the service loop. The permission is in
// before it returns, so the relay candidate can be advertised at once.
func StartListener(creds Credentials, requested []string, sshPort int, admit func(string) bool) (*Listener, Started, error) {
	if admit == nil {
		admit = IsPublicUnicast
	}
	ep, ok := PreferredRelayEndpoint(creds.URLs)
	if !ok {
		logx.Printf("p2p: no turn(s):…?transport=tcp URL in credentials")
		return nil, Started{}, errors.New("no TCP relay URL")
	}
	permitIPs := Admissible(requested, admit)
	if len(permitIPs) == 0 {
		logx.Printf("p2p: no public address to let in (%s) — relay skipped", strings.Join(requested, ", "))
		return nil, Started{}, errors.New("no admissible peer address")
	}
	client := NewClient(ep.Host, ep.Port, ep.TLS, creds.Username, creds.Credential)
	if err := client.Connect(5 * time.Second); err != nil {
		logx.Printf("p2p: relay %s:%d (%s) unreachable", ep.Host, ep.Port, mode(ep.TLS))
		// Deviation: the Swift has no runtime fallback; a network that
		// blocks 5349 still reaches the plain 3478/tcp endpoint.
		plain, ok := PreferredTCPEndpoint(creds.URLs)
		if !ep.TLS || !ok {
			return nil, Started{}, err
		}
		client = NewClient(plain.Host, plain.Port, false, creds.Username, creds.Credential)
		if err := client.Connect(5 * time.Second); err != nil {
			logx.Printf("p2p: relay %s:%d (TCP) unreachable", plain.Host, plain.Port)
			return nil, Started{}, err
		}
		ep = Endpoint{plain.Host, plain.Port, false}
	}
	alloc, err := client.AllocateTCP(6 * time.Second)
	if err != nil {
		logx.Printf("p2p: TURN allocate failed at %s:%d", ep.Host, ep.Port)
		client.Close()
		return nil, Started{}, err
	}
	if len(permitIPs) < len(requested) {
		logx.Printf("p2p: TURN permits only %s of %s", strings.Join(permitIPs, ", "), strings.Join(requested, ", "))
	}
	var permitted, retry []string
	for _, ip := range permitIPs {
		if client.CreatePermission(ip, 2*time.Second) {
			permitted = append(permitted, ip)
		} else {
			retry = append(retry, ip)
		}
	}
	if len(permitted) == 0 {
		logx.Printf("p2p: TURN permission for %s refused — retrying", strings.Join(permitIPs, ", "))
	}
	logx.Printf("p2p: TURN relay allocated %s:%d over %s %s:%d (lifetime %ds, permit %s)",
		alloc.RelayIP, alloc.RelayPort, mode(ep.TLS), ep.Host, ep.Port, alloc.Lifetime, strings.Join(permitted, ", "))
	l := &Listener{client: client, sshPort: sshPort, lifetime: alloc.Lifetime,
		permits: NewRelayPermits(permitted, retry, admit), idleSince: time.Now()}
	go l.serviceLoop()
	ttl := int(alloc.Lifetime)
	relay := signal.NewCandidate(signal.KindRelay, signal.ProtoTCP, alloc.RelayIP, alloc.RelayPort, &ttl)
	return l, Started{Relay: relay, MappedIP: alloc.MappedIP}, nil
}

func mode(tlsOn bool) string {
	if tlsOn {
		return "TLS"
	}
	return "TCP"
}

// Permit lets another peer IP in (a later srflx trickle).
func (l *Listener) Permit(ip string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if !l.permits.Add(ip) {
		logx.Printf("p2p: TURN relay won't let %s in (not a public address, or %d already)", ip, MaxAddresses)
	}
}

// Stop ends the session (wakes the service loop).
func (l *Listener) Stop() {
	l.mu.Lock()
	was := l.stopped
	l.stopped = true
	l.mu.Unlock()
	if !was {
		l.client.Close()
	}
}

func (l *Listener) isStopped() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.stopped
}

func (l *Listener) serviceLoop() {
	half := func(life uint32) time.Duration {
		h := life / 2
		if h < 60 {
			h = 60
		}
		return time.Duration(h) * time.Second
	}
	nextAlloc := time.Now().Add(half(l.lifetime))
	nextPerm := time.Now().Add(240 * time.Second)
	for !l.isStopped() {
		l.mu.Lock()
		ip, tries, has := l.permits.TakeOne()
		l.mu.Unlock()
		if has {
			ok := l.client.CreatePermission(ip, 2*time.Second)
			l.mu.Lock()
			again := l.permits.Record(ip, tries, ok)
			l.mu.Unlock()
			state := "installed"
			if !ok && again {
				state = "failed — retrying"
			} else if !ok {
				state = "failed — giving up"
			}
			logx.Printf("p2p: TURN permission for %s %s", ip, state)
		}

		ev, err := l.client.ReadEvent(time.Second)
		if err != nil && !errors.Is(err, ErrTimeout) {
			// Deviation: the Swift keeps polling a dead control socket
			// until the refresh fails; a closed relay ends the session now.
			if !l.isStopped() {
				logx.Printf("p2p: TURN control connection lost: %v", err)
			}
			break
		}
		if ev != nil && ev.Type == stun.ConnectionAttemptIndication {
			if id, ok := ev.U32(stun.AttrConnectionID); ok {
				pip, pport, _ := ev.XorAddress(stun.AttrXorPeerAddress)
				if pip == "" {
					pip = "?"
				}
				logx.Printf("p2p: relay connection attempt from %s:%d", pip, pport)
				l.mu.Lock()
				l.idleSince = time.Now()
				l.mu.Unlock()
				go l.serve(id)
			}
		}
		if l.isStopped() {
			break
		}
		l.mu.Lock()
		var idle time.Duration
		if l.activeLegs == 0 {
			idle = time.Since(l.idleSince)
		}
		l.mu.Unlock()
		if idle > IdleReapAfter {
			logx.Printf("p2p: TCP relay idle %ds with no legs — reaping allocation", int(idle.Seconds()))
			break
		}
		if !time.Now().Before(nextAlloc) {
			granted, ok := l.client.Refresh(5 * time.Second)
			if !ok {
				logx.Printf("p2p: TURN refresh failed — relay session over")
				break
			}
			nextAlloc = time.Now().Add(half(granted))
		}
		if !time.Now().Before(nextPerm) {
			l.mu.Lock()
			ips := append([]string(nil), l.permits.Installed...)
			l.mu.Unlock()
			for _, ip := range ips {
				if !l.client.CreatePermission(ip, 5*time.Second) {
					l.mu.Lock()
					l.permits.RenewalFailed(ip)
					l.mu.Unlock()
				}
			}
			nextPerm = time.Now().Add(240 * time.Second)
		}
	}
	l.client.Close()
	if l.OnStopped != nil {
		l.OnStopped()
	}
}

// LocalDial reaches the local SSH server (tests may swap it).
var LocalDial = func(port int) (net.Conn, error) {
	c, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), 5*time.Second)
	if err != nil {
		return nil, err
	}
	sockopt.TuneInteractive(c, true)
	return c, nil
}

// serve is one relayed leg: bind, then splice into the local SSH server.
func (l *Listener) serve(id uint32) {
	data, err := l.client.BindDataConnection(id, 6*time.Second)
	if err != nil {
		logx.Printf("p2p: ConnectionBind failed for id %d", id)
		return
	}
	ssh, err := LocalDial(l.sshPort)
	if err != nil {
		logx.Printf("p2p: local sshd :%d unreachable for relayed leg", l.sshPort)
		data.Close()
		return
	}
	l.mu.Lock()
	l.activeLegs++
	l.mu.Unlock()
	defer func() {
		l.mu.Lock()
		l.activeLegs--
		if l.activeLegs == 0 {
			l.idleSince = time.Now()
		}
		l.mu.Unlock()
	}()
	// The relay leg is the only socket that sees the far client die: bound
	// its stalled writes and retransmits.
	if !l.client.TLS {
		sockopt.BoundStalledPeer(data)
	}
	sockopt.Splice(data, ssh, true, false)
}

// String is for logs.
func (l *Listener) String() string { return fmt.Sprintf("relay(%s:%d)", l.client.Host, l.client.Port) }
