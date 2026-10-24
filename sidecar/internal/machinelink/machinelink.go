// Package machinelink attaches this machine to a Bromure AC account server
// (MachineLinker.swift) as one more machine in its lists: its agents
// appear in that app's sessions and reach its agents through that app's
// delegation engine. This side always dials: it keeps a few links parked
// there (the `machine-link` SSH verb, the only thing this machine's key may
// do on a server) and serves what comes down them (`control`: our control
// API; `delegation-mcp`: the next agent MCP stream). On Windows the target
// is always an account server (no local Bromure AC).
package machinelink

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/rderaison/bromure/sidecar/internal/delegation"
	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/paths"
	"github.com/rderaison/bromure/sidecar/internal/settings"
	"github.com/rderaison/bromure/sidecar/internal/sshdial"
	"github.com/rderaison/bromure/sidecar/internal/sshserver"
)

// Slots is how many links stay parked.
const Slots = 3

// Target is where to attach: an account server, through bromure.io and
// SSH. Its JSON is the Swift's Codable `.device(id:name:user:)`:
// {"device":{"id":…,"name":…,"user":…}}.
type Target struct {
	ID   string // the server's bromure.io device id
	Name string
	User string // the SSH user there
}

// ErrLocalTarget: a stored `.local` target (the Mac-only "this Mac's
// Bromure AC"), which has no meaning here.
var ErrLocalTarget = errors.New("machinelink: a local target can't be attached here")

type deviceJSON struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	User string `json:"user"`
}

func (t Target) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		Device deviceJSON `json:"device"`
	}{deviceJSON{t.ID, t.Name, t.User}})
}

func (t *Target) UnmarshalJSON(b []byte) error {
	var m map[string]json.RawMessage
	if err := json.Unmarshal(b, &m); err != nil {
		return err
	}
	if raw, ok := m["device"]; ok {
		var d deviceJSON
		if err := json.Unmarshal(raw, &d); err != nil {
			return err
		}
		*t = Target{ID: d.ID, Name: d.Name, User: d.User}
		return nil
	}
	if _, ok := m["local"]; ok {
		return ErrLocalTarget
	}
	return errors.New("machinelink: unknown target")
}

// Label is how the target is named to the user.
func (t Target) Label() string { return t.Name }

// Config is the linker's.
type Config struct {
	// Dial reaches the server's SSH port (the P2P dialer); the linker runs
	// SSH over the conn.
	Dial func(ctx context.Context, deviceID string) (net.Conn, error)
	// MachineName is this machine's name in the server's lists.
	MachineName func() string
	// HostID is this machine's id there (a UUID string, upper case, like
	// the Swift's hostID.uuidString).
	HostID func() string
	// ControlSocket answers `control` ("" = paths.ControlSocket()).
	ControlSocket string
	// Hub carries `delegation-mcp` streams (nil: those links are dropped).
	Hub *delegation.Hub
	// ClosePeer drops a cached P2P path to deviceID (a server that
	// restarted leaves it pointing at its old session). Optional.
	ClosePeer func(deviceID string)
	// SSH builds the SSH client over a dialed conn (nil = sshdial.Client,
	// pinned under sshdial.PeerToken(id)).
	SSH func(conn net.Conn, user, token string) (*ssh.Client, error)
	// DialTimeout bounds Dial (default 20 s, the Swift's endpoint timeout).
	DialTimeout time.Duration
}

// Status is what the tray and /sidecar/status show.
type Status struct {
	Target           *Target `json:"target,omitempty"`
	Linked           bool    `json:"linked"`
	AwaitingApproval bool    `json:"awaitingApproval"`
	Error            string  `json:"error,omitempty"`
}

// Linker keeps the links.
type Linker struct {
	cfg Config

	mu         sync.Mutex
	generation int
	target     *Target
	parked     int
	lastError  string
	live       map[*delegation.Watched]bool
	awaiting   bool // parked, but the server's user hasn't let us in yet
	cancel     context.CancelFunc

	poolMu   sync.Mutex
	buildMu  sync.Mutex
	pool     *ssh.Client
	poolKey  string
	poolDead chan struct{}

	// sleeps (tests shorten them)
	refusedPause time.Duration
	maxBackoff   time.Duration
	unit         time.Duration
}

// New makes a linker; nothing runs until Resume or Attach.
func New(cfg Config) *Linker {
	if cfg.ControlSocket == "" {
		cfg.ControlSocket = paths.ControlSocket()
	}
	if cfg.DialTimeout == 0 {
		cfg.DialTimeout = 20 * time.Second
	}
	if cfg.SSH == nil {
		cfg.SSH = sshdial.Client
	}
	if cfg.MachineName == nil {
		cfg.MachineName = func() string { return "" }
	}
	if cfg.HostID == nil {
		cfg.HostID = func() string { return "" }
	}
	return &Linker{cfg: cfg, live: map[*delegation.Watched]bool{},
		refusedPause: 120 * time.Second, maxBackoff: 10 * time.Second, unit: time.Second}
}

// Resume re-attaches where we were last time.
func (l *Linker) Resume() {
	var t Target
	if !settings.Get(settings.AttachTarget, &t) || t.ID == "" {
		return
	}
	l.Attach(t)
}

// Attach (re)starts the links to t, remembering it.
func (l *Linker) Attach(t Target) {
	l.Detach(false)
	if err := settings.Set(settings.AttachTarget, t); err != nil {
		logx.Printf("attach: couldn't save the target: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	l.mu.Lock()
	l.generation++
	gen := l.generation
	tt := t
	l.target = &tt
	l.lastError = ""
	l.cancel = cancel
	l.mu.Unlock()
	logx.Printf("attach: to %s", t.Label())
	for i := 0; i < Slots; i++ {
		go l.slotLoop(ctx, gen, t)
	}
}

// Detach stops attaching; forget also tells the server to drop this
// machine (machine-detach) and forgets the target.
func (l *Linker) Detach(forget bool) {
	l.mu.Lock()
	t := l.target
	l.generation++
	l.target = nil
	l.parked = 0
	links := l.live
	l.live = map[*delegation.Watched]bool{}
	if l.cancel != nil {
		l.cancel()
		l.cancel = nil
	}
	l.mu.Unlock()
	for w := range links {
		_ = w.Close()
	}
	if !forget {
		return
	}
	_ = settings.Remove(settings.AttachTarget)
	if t == nil {
		return
	}
	go func(t Target) {
		link, err := l.dial(t, sshserver.MachineDetachVerb(l.cfg.HostID()))
		if err == nil {
			b := make([]byte, 512)
			_, _ = link.Read(b)
			_ = link.Close()
		}
		l.closePool()
	}(*t)
}

// Status is the linker's state.
func (l *Linker) Status() Status {
	l.mu.Lock()
	defer l.mu.Unlock()
	st := Status{Linked: l.parked > 0, AwaitingApproval: l.awaiting && l.parked > 0, Error: l.lastError}
	if l.target != nil {
		t := *l.target
		st.Target = &t
	}
	return st
}

func (l *Linker) alive(gen int) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.generation == gen
}

func sleep(ctx context.Context, d time.Duration) {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
	case <-t.C:
	}
}

// MARK: one link at a time, for ever

func (l *Linker) slotLoop(ctx context.Context, gen int, t Target) {
	backoff := l.unit
	failures := 0
	grow := func() {
		backoff *= 2
		if backoff > l.maxBackoff {
			backoff = l.maxBackoff
		}
	}
	for l.alive(gen) {
		link, err := l.dial(t, sshserver.MachineLinkVerb(l.cfg.HostID(), l.cfg.MachineName()))
		if err != nil && !errors.Is(err, sshdial.ErrExecRefused) {
			l.note("Can't reach " + t.Label())
			// A server that restarted leaves the cached P2P path pointing
			// at its old session: drop it and let the next dial re-establish.
			failures++
			if failures >= 2 {
				l.closePool()
				if l.cfg.ClosePeer != nil {
					l.cfg.ClosePeer(t.ID)
				}
				failures = 0
			}
			sleep(ctx, backoff)
			grow()
			continue
		}
		if err != nil { // the exec was refused: an old server
			l.note(t.Label() + " didn't accept this machine (is it up to date?)")
			sleep(ctx, backoff)
			grow()
			continue
		}
		w := delegation.Watch(link)
		if !l.track(w, gen) {
			_ = w.Close()
			return
		}
		acc := readAccepted(w)
		switch acc.kind {
		case accepted:
			l.mu.Lock()
			l.awaiting = acc.pending
			l.mu.Unlock()
		case refused:
			// Blocked by the server's user (or refused outright): ask again
			// rarely, not every few seconds.
			l.untrack(w)
			_ = w.Close()
			if acc.why != "" {
				l.note(t.Label() + ": " + acc.why)
			} else {
				l.note(t.Label() + " refused this machine")
			}
			why := acc.why
			if why == "" {
				why = "?"
			}
			logx.Printf("attach: %s refused: %s", t.Label(), why)
			sleep(ctx, l.refusedPause)
			continue
		default:
			l.untrack(w)
			_ = w.Close()
			l.note(t.Label() + " didn't accept this machine (is it up to date?)")
			sleep(ctx, backoff)
			grow()
			continue
		}
		backoff = l.unit
		failures = 0
		l.setParked(+1)
		// Parked. The server writes a verb when it needs us.
		verb, ok := readLine(w)
		l.setParked(-1)
		if !ok {
			l.untrack(w)
			_ = w.Close()
			sleep(ctx, l.unit)
			continue
		}
		// A verb only comes to a machine in the fleet.
		l.mu.Lock()
		l.awaiting = false
		l.mu.Unlock()
		go func() {
			l.serve(w, verb)
			l.untrack(w)
			_ = w.Close()
		}()
	}
}

func (l *Linker) serve(w *delegation.Watched, verb string) {
	switch verb {
	case "control":
		// The server's request, answered by our own control API.
		ctl, err := net.DialTimeout("unix", l.cfg.ControlSocket, 5*time.Second)
		if err != nil {
			logx.Printf("attach: control socket: %v", err)
			return
		}
		delegation.Splice(w, ctl)
		_ = ctl.Close()
	case "delegation-mcp":
		if l.cfg.Hub == nil {
			logx.Printf("attach: delegation-mcp with no hub")
			return
		}
		// Carries the next agent MCP stream to the server's engine.
		done := make(chan struct{})
		var once sync.Once
		finish := func() { once.Do(func() { close(done) }) }
		l.cfg.Hub.Park(func(shim delegation.Stream) bool {
			// The server may have gone while this waited (or dropped a slot
			// nobody took): don't hand an agent's stream to a dead link.
			// nil: pruned by a later park.
			if shim == nil || !w.IsOpen() {
				finish()
				return false
			}
			go func() {
				delegation.Splice(w, shim)
				_ = shim.Close()
				finish()
			}()
			return true
		}, w.IsOpen)
		<-done
	default:
		logx.Printf("attach: unknown verb %s", verb)
	}
}

// MARK: connecting

// dial opens one exec channel for verb on the pooled SSH connection to t
// (built on first use), retrying once on a fresh connection when the
// pooled one turns out dead.
func (l *Linker) dial(t Target, verb string) (ssh.Channel, error) {
	var lastErr error
	for attempt := 0; attempt < 2; attempt++ {
		c, err := l.ensure(t)
		if err != nil {
			return nil, err
		}
		ch, err := sshdial.OpenExec(c, verb)
		if err == nil {
			return ch, nil
		}
		if errors.Is(err, sshdial.ErrExecRefused) {
			return nil, err
		}
		lastErr = err
		l.dropPool(c)
	}
	return nil, lastErr
}

func (l *Linker) ensure(t Target) (*ssh.Client, error) {
	key := t.ID + "|" + t.User
	if c := l.pooled(key); c != nil {
		return c, nil
	}
	l.buildMu.Lock()
	defer l.buildMu.Unlock()
	if c := l.pooled(key); c != nil {
		return c, nil
	}
	if l.cfg.Dial == nil {
		return nil, errors.New("machinelink: no dialer")
	}
	ctx, cancel := context.WithTimeout(context.Background(), l.cfg.DialTimeout)
	conn, err := l.cfg.Dial(ctx, t.ID)
	cancel()
	if err != nil {
		return nil, err
	}
	c, err := l.cfg.SSH(conn, t.User, sshdial.PeerToken(t.ID))
	if err != nil {
		return nil, err
	}
	dead := make(chan struct{})
	go func() { _ = c.Wait(); close(dead) }()
	l.poolMu.Lock()
	old := l.pool
	l.pool, l.poolKey, l.poolDead = c, key, dead
	l.poolMu.Unlock()
	if old != nil && old != c {
		_ = old.Close()
	}
	return c, nil
}

func (l *Linker) pooled(key string) *ssh.Client {
	l.poolMu.Lock()
	defer l.poolMu.Unlock()
	if l.pool == nil || l.poolKey != key {
		return nil
	}
	select {
	case <-l.poolDead:
		l.pool = nil
		return nil
	default:
		return l.pool
	}
}

func (l *Linker) dropPool(c *ssh.Client) {
	l.poolMu.Lock()
	if l.pool == c {
		l.pool = nil
	}
	l.poolMu.Unlock()
	_ = c.Close()
}

func (l *Linker) closePool() {
	l.poolMu.Lock()
	c := l.pool
	l.pool = nil
	l.poolMu.Unlock()
	if c != nil {
		_ = c.Close()
	}
}

// MARK: the park's reply

type acceptKind int

const (
	failed acceptKind = iota
	accepted
	refused
)

type acceptance struct {
	kind    acceptKind
	pending bool   // accepted, waiting for the server user's answer
	why     string // refused: the server's reason
}

// readAccepted reads the park's reply: in (or waiting for the user's
// answer), refused (403, with the reason from the JSON body, read up to
// Content-Length and no further), or no sense to be made of it. It never
// reads past what it needs: the verb line follows on the same stream.
func readAccepted(r io.Reader) acceptance {
	var head []byte
	b := make([]byte, 1)
	for len(head) < 4096 {
		n, err := r.Read(b)
		if n == 1 {
			head = append(head, b[0])
			if bytes.HasSuffix(head, []byte("\r\n\r\n")) {
				break
			}
			continue
		}
		if err != nil {
			return acceptance{kind: failed}
		}
	}
	text := string(head)
	if strings.HasPrefix(text, "HTTP/1.1 200") {
		return acceptance{kind: accepted, pending: strings.Contains(strings.ToLower(text), "x-bromure-fleet: pending")}
	}
	if !strings.HasPrefix(text, "HTTP/1.1 403") {
		return acceptance{kind: failed}
	}
	length := 0
	lower := strings.ToLower(text)
	if i := strings.Index(lower, "content-length:"); i >= 0 {
		rest := strings.TrimLeft(text[i+len("content-length:"):], " ")
		j := 0
		for j < len(rest) && rest[j] >= '0' && rest[j] <= '9' {
			j++
		}
		length, _ = strconv.Atoi(rest[:j])
	}
	if length < 0 {
		length = 0
	}
	if length > 4096 {
		length = 4096
	}
	body := make([]byte, length)
	got := 0
	for got < len(body) {
		n, err := r.Read(body[got:])
		got += n
		if err != nil || n <= 0 {
			break
		}
	}
	var msg map[string]any
	_ = json.Unmarshal(body[:got], &msg)
	why, _ := msg["error"].(string)
	return acceptance{kind: refused, why: why}
}

// readLine reads one verb line (up to 256 bytes) without reading past it.
func readLine(r io.Reader) (string, bool) {
	var line []byte
	b := make([]byte, 1)
	for len(line) < 256 {
		n, err := r.Read(b)
		if n == 1 {
			if b[0] == '\n' {
				return string(line), true
			}
			line = append(line, b[0])
			continue
		}
		if err != nil {
			return "", false
		}
	}
	return "", false
}

// MARK: bookkeeping

func (l *Linker) track(w *delegation.Watched, gen int) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.generation != gen {
		return false
	}
	l.live[w] = true
	return true
}

func (l *Linker) untrack(w *delegation.Watched) {
	l.mu.Lock()
	delete(l.live, w)
	l.mu.Unlock()
}

func (l *Linker) setParked(delta int) {
	l.mu.Lock()
	l.parked += delta
	if l.parked < 0 {
		l.parked = 0
	}
	if l.parked > 0 {
		l.lastError = ""
	}
	l.mu.Unlock()
}

func (l *Linker) note(err string) {
	l.mu.Lock()
	if l.parked == 0 {
		l.lastError = err
	}
	l.mu.Unlock()
}
