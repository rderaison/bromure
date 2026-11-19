// Package sshdial is the Sidecar's SSH client (FatClientSSHDial.swift):
// its ed25519 identity (client_ed25519, a raw 32-byte seed), the
// known_hosts pin store (accept-new TOFU, or strict), and an SSH
// connection over a transport someone else established (the P2P dialer's
// conn), with exec channels opened on it under the Swift's stall rules.
package sshdial

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/paths"
)

// ClientKeyComment is the comment on the published client key line.
const ClientKeyComment = "bromure-agent-host"

var keyMu sync.Mutex

// ClientKey loads the client identity, generating it on first use (an
// owner-only file holding the raw 32-byte seed, like the Swift's ClientKey).
func ClientKey() (ed25519.PrivateKey, error) {
	keyMu.Lock()
	defer keyMu.Unlock()
	p := paths.ClientKey()
	if d, err := os.ReadFile(p); err == nil && len(d) == ed25519.SeedSize {
		return ed25519.NewKeyFromSeed(d), nil
	}
	seed := make([]byte, ed25519.SeedSize)
	if _, err := rand.Read(seed); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return nil, err
	}
	if err := writeFileAtomic(p, seed); err != nil {
		return nil, err
	}
	_ = paths.ProtectFile(p)
	return ed25519.NewKeyFromSeed(seed), nil
}

// ClientSigner is ClientKey as an SSH signer.
func ClientSigner() (ssh.Signer, error) {
	k, err := ClientKey()
	if err != nil {
		return nil, err
	}
	return ssh.NewSignerFromKey(k)
}

// ClientPublicKeyLine is the OpenSSH line published to the account
// ("ssh-ed25519 <b64> bromure-agent-host"). Never the host key.
func ClientPublicKeyLine() (string, error) {
	s, err := ClientSigner()
	if err != nil {
		return "", err
	}
	return PublicLine(s.PublicKey(), ClientKeyComment), nil
}

// PublicLine is "<algo> <b64 blob> <comment>".
func PublicLine(k ssh.PublicKey, comment string) string {
	line := k.Type() + " " + base64.StdEncoding.EncodeToString(k.Marshal())
	if comment != "" {
		line += " " + comment
	}
	return line
}

// Fingerprint is "SHA256:<unpadded b64>", ssh-keygen -l's format.
func Fingerprint(k ssh.PublicKey) string {
	sum := sha256.Sum256(k.Marshal())
	return "SHA256:" + base64.RawStdEncoding.EncodeToString(sum[:])
}

// MARK: known_hosts

// HostToken is a known_hosts host token: host (port 22) or [host]:port.
func HostToken(address string, port int) string {
	if port == 22 {
		return address
	}
	return fmt.Sprintf("[%s]:%d", address, port)
}

// PeerToken is the pin alias of an account device reached over P2P (its
// endpoint changes every session; its identity doesn't).
func PeerToken(deviceID string) string { return "bromure-peer-" + deviceID }

// KnownHosts is the pin store: lines "<token> <algo> <b64>", read and
// written in-process (KnownHostsStore).
type KnownHosts struct{ Path string }

// DefaultKnownHosts is the data dir's known_hosts.
func DefaultKnownHosts() KnownHosts { return KnownHosts{Path: paths.KnownHosts()} }

var khMu sync.Mutex

func (k KnownHosts) lines() []string {
	b, err := os.ReadFile(k.Path)
	if err != nil {
		return nil
	}
	var out []string
	for _, l := range strings.FieldsFunc(string(b), func(r rune) bool { return r == '\n' || r == '\r' }) {
		if l != "" {
			out = append(out, l)
		}
	}
	return out
}

func firstToken(line string) string {
	if f := strings.FieldsFunc(line, func(r rune) bool { return r == ' ' }); len(f) > 0 {
		return f[0]
	}
	return ""
}

// PinnedLine is the pinned line for token ("" if none).
func (k KnownHosts) PinnedLine(token string) string {
	khMu.Lock()
	defer khMu.Unlock()
	for _, l := range k.lines() {
		if firstToken(l) == token {
			return l
		}
	}
	return ""
}

// Pinned is the pinned key for token (nil if none or unparsable).
func (k KnownHosts) Pinned(token string) ssh.PublicKey {
	line := k.PinnedLine(token)
	parts := strings.SplitN(line, " ", 2)
	if len(parts) != 2 {
		return nil
	}
	pk, _, _, _, err := ssh.ParseAuthorizedKey([]byte(parts[1]))
	if err != nil {
		return nil
	}
	return pk
}

// HasPin reports whether token is pinned.
func (k KnownHosts) HasPin(token string) bool { return k.PinnedLine(token) != "" }

// Pin replaces any prior entry for token with key.
func (k KnownHosts) Pin(token string, key ssh.PublicKey) error {
	khMu.Lock()
	defer khMu.Unlock()
	var kept []string
	for _, l := range k.lines() {
		if firstToken(l) != token {
			kept = append(kept, l)
		}
	}
	kept = append(kept, token+" "+PublicLine(key, ""))
	if err := os.MkdirAll(filepath.Dir(k.Path), 0o700); err != nil {
		return err
	}
	return writeFileAtomic(k.Path, []byte(strings.Join(kept, "\n")+"\n"))
}

// MARK: connections

// Errors out of a connection build, classified like SSHDialError.
var (
	ErrAuthFailed     = errors.New("ssh: this machine's key was not accepted")
	ErrHostKeyChanged = errors.New("ssh: the server's host key changed (or isn't pinned)")
	errNoPin          = errors.New("ssh: no host key pin")
)

// Unreachable is any other build failure (transport: heals by retrying).
type Unreachable struct{ Err error }

func (u *Unreachable) Error() string { return "ssh: unreachable: " + firstLine(u.Err.Error()) }
func (u *Unreachable) Unwrap() error { return u.Err }

// Timeouts (SSHConnection / LinkTimeouts).
var (
	// HandshakeIdle aborts a handshake only after this long with no inbound
	// bytes: a stall, not a slow link.
	HandshakeIdle = 20 * time.Second
	// HandshakeEnvelope is the hard backstop on the whole handshake + auth.
	HandshakeEnvelope = 5 * time.Minute
	// ChannelOpenStall: how long a channel open may wait with the
	// connection otherwise silent before it's declared wedged.
	ChannelOpenStall = 15 * time.Second
	// ChannelOpenCeiling: the hard ceiling while bytes keep arriving.
	ChannelOpenCeiling = 90 * time.Second
)

// Options for ClientWith.
type Options struct {
	User string
	// Token is the known_hosts token (HostToken / PeerToken).
	Token string
	// Strict: the host key MUST match an existing pin; otherwise
	// accept-new (pin on first contact, refuse a changed key).
	Strict bool
	// KnownHosts; zero = DefaultKnownHosts. Path "-" = no store (refuse).
	KnownHosts KnownHosts
	// Signer; nil = ClientSigner().
	Signer ssh.Signer
}

// Client runs SSH over an established transport conn as user, pinning the
// host key under the known_hosts token hostLabel (accept-new, as the
// Sidecar's dialer). The conn is the client's from then on.
func Client(conn net.Conn, user, hostLabel string) (*ssh.Client, error) {
	return ClientWith(conn, Options{User: user, Token: hostLabel})
}

// activityConn stamps the time of every inbound read.
type activityConn struct {
	net.Conn
	last atomic.Int64 // unix nanos
}

func (a *activityConn) Read(p []byte) (int, error) {
	n, err := a.Conn.Read(p)
	if n > 0 {
		a.last.Store(time.Now().UnixNano())
	}
	return n, err
}

func (a *activityConn) quiet() time.Duration {
	return time.Since(time.Unix(0, a.last.Load()))
}

var (
	actMu      sync.Mutex
	activities = map[*ssh.Client]*activityConn{}
)

// ClientWith is Client with every knob.
func ClientWith(conn net.Conn, o Options) (*ssh.Client, error) {
	signer := o.Signer
	if signer == nil {
		var err error
		if signer, err = ClientSigner(); err != nil {
			_ = conn.Close()
			return nil, ErrAuthFailed
		}
	}
	kh := o.KnownHosts
	if kh.Path == "" {
		kh = DefaultKnownHosts()
	}
	logx.Printf("ssh-dial: offering key %s to %s", Fingerprint(signer.PublicKey()), o.Token)

	var flagged atomic.Value // error
	cfg := &ssh.ClientConfig{
		User: o.User,
		Auth: []ssh.AuthMethod{ssh.PublicKeys(signer)},
		HostKeyCallback: func(_ string, _ net.Addr, key ssh.PublicKey) error {
			if kh.Path == "-" {
				flagged.Store(ErrHostKeyChanged)
				return errNoPin
			}
			if pinned := kh.Pinned(o.Token); pinned != nil {
				if string(pinned.Marshal()) == string(key.Marshal()) {
					return nil
				}
				flagged.Store(ErrHostKeyChanged)
				return ErrHostKeyChanged
			}
			if o.Strict {
				flagged.Store(ErrHostKeyChanged)
				return errNoPin
			}
			if err := kh.Pin(o.Token, key); err != nil {
				logx.Printf("ssh-dial: couldn't pin %s: %v", o.Token, err)
			}
			return nil
		},
	}
	if kh.Path != "-" {
		if pinned := kh.Pinned(o.Token); pinned != nil {
			cfg.HostKeyAlgorithms = algorithmsFor(pinned.Type())
		}
	}

	ac := &activityConn{Conn: conn}
	ac.last.Store(time.Now().UnixNano())
	// Stall watchdog: abort only on inbound silence, with a hard envelope.
	done := make(chan struct{})
	start := time.Now()
	go func() {
		t := time.NewTicker(250 * time.Millisecond)
		defer t.Stop()
		for {
			select {
			case <-done:
				return
			case <-t.C:
			}
			if q := ac.quiet(); q >= HandshakeIdle {
				logx.Printf("ssh-dial: handshake stalled (no data for %ds) %s — closing", int(q/time.Second), o.Token)
				_ = conn.Close()
				return
			}
			if time.Since(start) >= HandshakeEnvelope {
				_ = conn.Close()
				return
			}
		}
	}()
	c, chans, reqs, err := ssh.NewClientConn(ac, o.Token, cfg)
	close(done)
	if err != nil {
		_ = conn.Close()
		if f, ok := flagged.Load().(error); ok && f != nil {
			return nil, f
		}
		if strings.Contains(err.Error(), "unable to authenticate") {
			return nil, ErrAuthFailed
		}
		return nil, &Unreachable{Err: err}
	}
	logx.Printf("ssh-dial: handshake+auth OK %s@%s", o.User, o.Token)
	client := ssh.NewClient(c, chans, reqs)
	actMu.Lock()
	activities[client] = ac
	actMu.Unlock()
	go func() {
		_ = client.Wait()
		actMu.Lock()
		delete(activities, client)
		actMu.Unlock()
	}()
	return client, nil
}

func algorithmsFor(t string) []string {
	switch t {
	case ssh.KeyAlgoRSA:
		return []string{ssh.KeyAlgoRSASHA512, ssh.KeyAlgoRSASHA256, ssh.KeyAlgoRSA}
	default:
		return []string{t}
	}
}

// ErrExecRefused: the server declined the exec request.
var ErrExecRefused = errors.New("ssh: exec refused")

// ErrChannelOpenTimeout: the channel open (or its exec) stalled; the
// connection was closed as wedged.
var ErrChannelOpenTimeout = errors.New("ssh: channel open timed out")

// OpenExec opens a session channel on c and execs verb on it, returning
// the channel as a byte stream (stdout; stderr is drained and dropped, as
// the Swift's ExecFDPumpHandler does). A connection that stays silent past
// ChannelOpenStall while the open waits (busy is fine, up to
// ChannelOpenCeiling) is closed as wedged, so the next dial builds fresh.
func OpenExec(c *ssh.Client, verb string) (ssh.Channel, error) {
	type result struct {
		ch  ssh.Channel
		err error
	}
	res := make(chan result, 1)
	var abandoned atomic.Bool
	go func() {
		ch, reqs, err := c.OpenChannel("session", nil)
		if err != nil {
			res <- result{nil, err}
			return
		}
		go ssh.DiscardRequests(reqs)
		ok, err := ch.SendRequest("exec", true, ssh.Marshal(struct{ Command string }{verb}))
		if err == nil && !ok {
			err = ErrExecRefused
		}
		if err != nil {
			_ = ch.Close()
			res <- result{nil, err}
			return
		}
		if abandoned.Load() {
			_ = ch.Close()
			return
		}
		go func() {
			buf := make([]byte, 4096)
			for {
				if _, err := ch.Stderr().Read(buf); err != nil {
					return
				}
			}
		}()
		res <- result{ch, nil}
	}()

	actMu.Lock()
	ac := activities[c]
	actMu.Unlock()
	opened := time.Now()
	wait := ChannelOpenStall
	for {
		t := time.NewTimer(wait)
		select {
		case r := <-res:
			t.Stop()
			return r.ch, r.err
		case <-t.C:
		}
		var quiet time.Duration = ChannelOpenStall
		if ac != nil {
			quiet = ac.quiet()
		}
		waited := time.Since(opened)
		if quiet < ChannelOpenStall && waited < ChannelOpenCeiling {
			// Busy, not dead: wait until it's been ChannelOpenStall quiet.
			wait = ChannelOpenStall - quiet
			if wait < time.Second {
				wait = time.Second
			}
			continue
		}
		logx.Printf("ssh-dial: channel open timed out after %ds (connection quiet %ds) — dropping wedged connection",
			int(waited/time.Second), int(quiet/time.Second))
		abandoned.Store(true)
		_ = c.Close()
		// The open may still land between the store and the close.
		select {
		case r := <-res:
			if r.ch != nil {
				_ = r.ch.Close()
			}
		default:
		}
		return nil, ErrChannelOpenTimeout
	}
}

func firstLine(s string) string {
	for _, l := range strings.Split(s, "\n") {
		if strings.TrimSpace(l) != "" {
			return l
		}
	}
	return s
}

func writeFileAtomic(p string, data []byte) error {
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, p); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}
