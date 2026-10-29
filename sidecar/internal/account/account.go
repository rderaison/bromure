// Package account is the Sidecar as a bromure.io device, ported from
// Sources/AgentHost/P2PAccount.swift: browser enrollment through the
// `bromure-agent-host://` handoff, relay-only serving, the account's
// servers, and key sync (every 180 s and on the device channel's
// keys-changed): publish this machine's client key and login, install the
// account's device keys as managed authorized_keys lines.
package account

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/p2p"
	"github.com/rderaison/bromure/sidecar/internal/p2p/controlplane"
	"github.com/rderaison/bromure/sidecar/internal/p2p/identity"
	"github.com/rderaison/bromure/sidecar/internal/paths"
	"github.com/rderaison/bromure/sidecar/internal/settings"
)

const (
	// URLScheme is what bromure.io's enroll page hands the code back to
	// when opened with app=agent-host.
	URLScheme = "bromure-agent-host"
	// AccountKeyMarker prefixes every managed authorized_keys comment.
	AccountKeyMarker = "bromure-account:"
	// ClientKeyComment is the comment on the published client key.
	ClientKeyComment = "bromure-agent-host"
	// EnrollURL is bromure.io's device handoff page.
	EnrollURL = "https://bromure.io/app/enroll"
	// SyncEvery is the key-sync period.
	SyncEvery = 180 * time.Second
)

// Config is what the daemon wires in.
type Config struct {
	SSHPort         int
	MachineName     func() string
	UserName        string                 // bare %USERNAME%, never DOMAIN\user
	ClientPublicKey func() (string, error) // OpenSSH line of client_ed25519
	SetManagedKeys  func(marker string, lines []string)
	OpenURL         func(string) error
	// HTTP overrides the control-plane client (tests).
	HTTP *http.Client
}

// Status is the sign-in state for the tray and /state.
type Status struct {
	SignedIn   bool   `json:"signedIn"`
	DeviceID   string `json:"deviceId,omitempty"`
	DeviceName string `json:"deviceName,omitempty"`
	Capability string `json:"capability,omitempty"`
	Serving    bool   `json:"serving"`
	Connected  bool   `json:"channelConnected"`
	Enrolling  bool   `json:"enrolling"`
	LastError  string `json:"lastError,omitempty"`
}

// Server is one account server this machine can attach to.
type Server struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Capability  string `json:"capability,omitempty"`
	Online      bool   `json:"online"`
	LastSeenAt  string `json:"lastSeenAt,omitempty"`
	SSHUsername string `json:"sshUsername,omitempty"`
}

// Account is the one bromure.io device this Sidecar is.
type Account struct {
	cfg    Config
	broker *p2p.Broker

	mu        sync.Mutex
	lastError string
	servers   []Server
	enrolling bool
	stopSync  chan struct{}
}

// New builds the account (nothing runs until Start).
func New(cfg Config) *Account {
	if cfg.SSHPort == 0 {
		cfg.SSHPort = settings.SSHPortValue()
	}
	if cfg.MachineName == nil {
		cfg.MachineName = func() string { h, _ := os.Hostname(); return h }
	}
	a := &Account{cfg: cfg, broker: p2p.NewBroker()}
	a.broker.HTTP = cfg.HTTP
	a.broker.OnKeysChanged = a.SyncKeys
	a.broker.OnRevoked = func() {
		a.mu.Lock()
		a.servers = nil
		a.lastError = "This machine was removed from your bromure.io account."
		a.mu.Unlock()
		a.stopKeySync()
	}
	return a
}

// Broker is the P2P engine (MachineLinker's dialer, tests).
func (a *Account) Broker() *p2p.Broker { return a.broker }

// PendingStateFile is where BeginSignIn keeps the handoff state.
func PendingStateFile() string { return filepath.Join(paths.DataDir(), settings.PendingEnroll) }

// IsAgentHostDevice: the record's capability is agent-host.
func IsAgentHostDevice() bool {
	r, res := identity.Load()
	return res == identity.Found && r.Capability == "agent-host"
}

func (a *Account) identity() (identity.Identity, bool) { return a.broker.Identity() }

func (a *Account) client() (*controlplane.Client, identity.Identity, bool) {
	id, ok := a.identity()
	if !ok {
		return nil, id, false
	}
	ep, err := controlplane.NewEndpoint(id.APIBase)
	if err != nil {
		return nil, id, false
	}
	c := controlplane.New(ep)
	if a.cfg.HTTP != nil {
		c.HTTP = a.cfg.HTTP
	}
	return c, id, true
}

// Start serves (relay only) and syncs keys when enrolled.
func (a *Account) Start() {
	id, ok := a.identity()
	if !ok {
		return
	}
	a.broker.StartServing(a.cfg.SSHPort)
	a.startKeySync()
	logx.Printf("p2p: serving (relay only) as device %s", id.InstallID)
}

func newState() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return strings.ToUpper(fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16]))
}

// enrollOS names this platform for the enroll page, in the value set the
// page understands; anything else it ignores, and reads as neutral.
func enrollOS() string {
	switch runtime.GOOS {
	case "linux":
		return "linux"
	case "darwin":
		return "macos"
	case "windows":
		return "windows"
	}
	return ""
}

// enrollHost is the machine name the page shows beside its heading. Display
// only, so control characters go and the length is capped: this travels in a
// URL the user may have to retype off another screen.
func enrollHost(name string) string {
	name = strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, strings.TrimSpace(name))
	if r := []rune(name); len(r) > 64 {
		name = string(r[:64])
	}
	return name
}

// BeginSignIn writes a fresh handoff state and opens bromure.io's enroll
// page; the browser comes back as bromure-agent-host://enroll?code=…&state=….
func (a *Account) BeginSignIn() (string, error) {
	state := newState()
	if err := os.MkdirAll(paths.DataDir(), 0o700); err != nil {
		return "", err
	}
	if err := os.WriteFile(PendingStateFile(), []byte(state), 0o600); err != nil {
		return "", err
	}
	a.mu.Lock()
	a.lastError = ""
	a.mu.Unlock()
	u := EnrollURL + "?capability=agent-host&state=" + url.QueryEscape(state) + "&app=agent-host"
	// What the page cannot work out for itself: which OS is being enrolled,
	// and what it is called. The browser is routinely on a DIFFERENT machine
	// than the enrollee -- that is the whole point of the handoff on a
	// headless host -- so sniffing the User-Agent there would confidently
	// name the wrong platform. An omitted or unknown os= leaves the page on
	// its neutral wording.
	if osName := enrollOS(); osName != "" {
		u += "&os=" + osName
	}
	if a.cfg.MachineName != nil {
		if h := enrollHost(a.cfg.MachineName()); h != "" {
			u += "&host=" + url.QueryEscape(h)
		}
	}
	if a.cfg.OpenURL != nil {
		if err := a.cfg.OpenURL(u); err != nil {
			logx.Printf("p2p: opening the enroll page failed: %v", err)
		}
	}
	return u, nil
}

// ErrNotALink: the text isn't an enrollment link or code.
var ErrNotALink = errors.New("That isn't an enrollment link or code.")

// ErrNotOurs: a link whose state isn't the handoff we started (ignored).
var ErrNotOurs = errors.New("ignored an enroll link this machine didn't start")

// Complete redeems a handed-back link (or a pasted code), then serves as
// the new device. Synchronous; Status().Enrolling is true meanwhile.
func (a *Account) Complete(raw string) error {
	link, ok := identity.ParseLink(raw)
	if !ok {
		a.setError(ErrNotALink.Error())
		return ErrNotALink
	}
	if state, has := identity.QueryValue(raw, "state"); has {
		pending, _ := os.ReadFile(PendingStateFile())
		if state != string(pending) {
			logx.Printf("p2p: ignored an enroll link we didn't start")
			return ErrNotOurs
		}
	}
	_ = os.Remove(PendingStateFile())
	// A re-enroll replaces the device: its channel goes first.
	a.broker.StopServing()
	a.stopKeySync()
	a.mu.Lock()
	a.enrolling = true
	a.mu.Unlock()
	name := a.cfg.MachineName()
	var hc *controlplane.Client
	if a.cfg.HTTP != nil {
		hc = &controlplane.Client{HTTP: a.cfg.HTTP}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	rec, err := identity.Enroll(ctx, link, &name, nil, hc)
	cancel()
	a.mu.Lock()
	a.enrolling = false
	a.mu.Unlock()
	if err != nil {
		a.setError("Sign-in failed: " + err.Error())
		logx.Printf("p2p: enroll failed: %v", err)
		return err
	}
	a.setError("")
	logx.Printf("p2p: enrolled as device %s", rec.DeviceID)
	a.Start()
	return nil
}

func (a *Account) setError(s string) {
	a.mu.Lock()
	a.lastError = s
	a.mu.Unlock()
}

// SignOut leaves the account: server mode off, serving stopped, the record
// erased, the published marker and the managed keys dropped.
func (a *Account) SignOut() {
	if c, id, ok := a.client(); ok {
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			_, _ = c.SetServerMode(ctx, id.Bearer, false)
		}()
	}
	a.broker.StopServing()
	a.stopKeySync()
	identity.Erase()
	_ = settings.Remove(settings.P2PPublished)
	a.mu.Lock()
	a.servers = nil
	a.mu.Unlock()
	if a.cfg.SetManagedKeys != nil {
		a.cfg.SetManagedKeys(AccountKeyMarker, nil)
	}
}

// Status is the current state.
func (a *Account) Status() Status {
	a.mu.Lock()
	st := Status{Enrolling: a.enrolling, LastError: a.lastError}
	a.mu.Unlock()
	if rec, res := identity.Load(); res == identity.Found {
		st.SignedIn = true
		st.DeviceID = rec.DeviceID
		st.Capability = rec.Capability
		st.DeviceName = a.cfg.MachineName()
	}
	st.Serving = a.broker.Serving()
	st.Connected = a.broker.ChannelConnected()
	return st
}

// Servers is the last directory fetch.
func (a *Account) Servers() []Server {
	a.mu.Lock()
	defer a.mu.Unlock()
	return append([]Server(nil), a.servers...)
}

// RefreshServers re-reads the directory: online, not self, not revoked,
// not another Sidecar (nothing to attach to there).
func (a *Account) RefreshServers() {
	c, id, ok := a.client()
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	devices, err := c.ListDevices(ctx, id.Bearer)
	if err != nil {
		return
	}
	var out []Server
	for _, d := range devices {
		if d.IsSelf || d.Revoked || !d.Online || d.IsAgentHost() {
			continue
		}
		s := Server{ID: d.ID, Name: d.DisplayName(), Online: d.Online}
		if d.Capability != nil {
			s.Capability = *d.Capability
		}
		if d.LastSeenAt != nil {
			s.LastSeenAt = *d.LastSeenAt
		}
		if d.SSHUsername != nil {
			s.SSHUsername = *d.SSHUsername
		}
		out = append(out, s)
	}
	a.mu.Lock()
	a.servers = out
	a.mu.Unlock()
}

func (a *Account) startKeySync() {
	a.mu.Lock()
	if a.stopSync != nil {
		close(a.stopSync)
	}
	stop := make(chan struct{})
	a.stopSync = stop
	a.mu.Unlock()
	go func() {
		a.SyncKeys()
		a.RefreshServers()
		t := time.NewTicker(SyncEvery)
		defer t.Stop()
		for {
			select {
			case <-stop:
				return
			case <-t.C:
				a.SyncKeys()
				a.RefreshServers()
			}
		}
	}()
}

func (a *Account) stopKeySync() {
	a.mu.Lock()
	if a.stopSync != nil {
		close(a.stopSync)
		a.stopSync = nil
	}
	a.mu.Unlock()
}

// ClientKeyLine is the published form of an OpenSSH line: type, blob and
// the bromure-agent-host comment.
func ClientKeyLine(line string) (string, bool) {
	f := strings.Fields(line)
	if len(f) < 2 {
		return "", false
	}
	return f[0] + " " + f[1] + " " + ClientKeyComment, true
}

// ManagedLines turns the account's keys into authorized_keys lines.
func ManagedLines(keys []controlplane.DeviceSSHKey) []string {
	var lines []string
	for _, k := range keys {
		p := strings.Fields(k.SSHPublicKey)
		if len(p) < 2 {
			continue
		}
		lines = append(lines, p[0]+" "+p[1]+" "+k.AuthorizedKeysComment())
	}
	return lines
}

var syncMu sync.Mutex

// SyncKeys publishes this machine's client key and login (once per device,
// user and key) and installs the account's device keys. Only for a device
// bromure.io knows as agent-host: one enrolled otherwise would publish a key
// servers trust fully, so it publishes nothing.
func (a *Account) SyncKeys() {
	syncMu.Lock()
	defer syncMu.Unlock()
	c, id, ok := a.client()
	if !ok || a.cfg.ClientPublicKey == nil {
		return
	}
	line, err := a.cfg.ClientPublicKey()
	if err != nil {
		return
	}
	key, ok := ClientKeyLine(line)
	if !ok {
		return
	}
	if !IsAgentHostDevice() {
		a.setError("Enrolled without the agent-host capability — sign out and sign in again to attach to servers.")
		return
	}
	user := a.cfg.UserName
	published := id.InstallID + " " + user + " " + key
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	if settings.String(settings.P2PPublished, "") != published {
		if err := c.UploadSSHKey(ctx, id.Bearer, key, user); err != nil {
			logx.Printf("p2p: publishing the login failed: %v", err)
		} else {
			_ = settings.Set(settings.P2PPublished, published)
		}
	}
	keys, err := c.ListSSHKeys(ctx, id.Bearer)
	if err != nil {
		return
	}
	if a.cfg.SetManagedKeys != nil {
		a.cfg.SetManagedKeys(AccountKeyMarker, ManagedLines(keys))
	}
}

// Dial reaches an account server's SSH port over P2P (MachineLinker).
func (a *Account) Dial(ctx context.Context, deviceID string) (net.Conn, error) {
	return a.broker.Dial(ctx, deviceID)
}

// ClosePeer drops a server's cached path (MachineLinker after repeated
// failures, as the Swift calls P2PBroker.closePeer).
func (a *Account) ClosePeer(deviceID string) { a.broker.ClosePeer(deviceID) }

// Close stops everything (daemon shutdown); the record stays.
func (a *Account) Close() {
	a.stopKeySync()
	a.broker.Close()
}
