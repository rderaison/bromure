// Package controlplane is the bromure.io device/connection REST client,
// ported from Sources/AgentCoding/P2P/ControlPlaneClient.swift (the routes
// the Sidecar uses; the iOS push and notification routes are left out).
// Auth is the opaque deviceToken bearer on every call except enrollment.
// No retries here; the caller decides backoff.
package controlplane

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/p2p/signal"
)

// EnrollBeginResponse is POST /v1/devices/enroll phase 1.
type EnrollBeginResponse struct {
	ChallengeID      string `json:"challengeId"`
	Challenge        string `json:"challenge"`
	SignPayload      string `json:"signPayload"` // signed verbatim
	Capability       string `json:"capability"`
	ExpiresInSeconds int    `json:"expiresInSeconds"`
}

// EnrollCompleteResponse is POST /v1/devices/enroll phase 2.
type EnrollCompleteResponse struct {
	DeviceID             string  `json:"deviceId"`
	DeviceToken          string  `json:"deviceToken"`
	DeviceTokenExpiresAt *string `json:"deviceTokenExpiresAt"`
	Capability           string  `json:"capability"`
	OrgSlug              *string `json:"orgSlug"`
	OrgKind              *string `json:"orgKind"`
	UserID               *string `json:"userId"`
}

// DeviceInfo is one row of GET /v1/devices.
type DeviceInfo struct {
	ID          string  `json:"id"`
	Name        *string `json:"name"`
	Capability  *string `json:"capability"`
	Revoked     bool    `json:"revoked"`
	Online      bool    `json:"online"`
	LastSeenAt  *string `json:"lastSeenAt"`
	IsSelf      bool    `json:"self"`
	SSHUsername *string `json:"sshUsername"`
}

func (d DeviceInfo) IsServer() bool    { return d.Capability != nil && *d.Capability == "server" }
func (d DeviceInfo) IsAgentHost() bool { return d.Capability != nil && *d.Capability == "agent-host" }

// DisplayName is the name, else the id's first 8 characters.
func (d DeviceInfo) DisplayName() string {
	if d.Name != nil && *d.Name != "" {
		return *d.Name
	}
	if len(d.ID) > 8 {
		return d.ID[:8]
	}
	return d.ID
}

// TurnCredentials is POST /v1/connections/:id/turn-credentials ({"turn":{…}}).
type TurnCredentials struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username"`
	Credential string   `json:"credential"`
	TTLSeconds int      `json:"ttlSeconds"`
	ExpiresAt  string   `json:"expiresAt"`
	Region     string   `json:"region"`
}

// ConnectionReport is POST /v1/connections/:id/complete's body.
type ConnectionReport struct {
	Outcome           string `json:"outcome"`
	PathKind          string `json:"pathKind,omitempty"`
	TimeToConnectedMs *int   `json:"timeToConnectedMs,omitempty"`
	FailureStage      string `json:"failureStage,omitempty"`
}

// Connected is a success report (the server forbids failureStage on it).
func Connected(pathKind string, ms int) ConnectionReport {
	if ms < 0 {
		ms = 0
	}
	if ms > 600000 {
		ms = 600000
	}
	return ConnectionReport{Outcome: "connected", PathKind: pathKind, TimeToConnectedMs: &ms}
}

// Failed is a failure report (no path fields allowed).
func Failed(stage string) ConnectionReport {
	return ConnectionReport{Outcome: "failed", FailureStage: stage}
}

// DeviceSSHKey is one row of GET /v1/devices/ssh-keys.
type DeviceSSHKey struct {
	ID           string  `json:"id"`
	Name         *string `json:"name"`
	SSHPublicKey string  `json:"sshPublicKey"`
	Capability   *string `json:"capability"`
}

// AuthorizedKeysComment tags the key in authorized_keys; agent-host keys
// may only attach their machine.
func (k DeviceSSHKey) AuthorizedKeysComment() string {
	if k.Capability != nil && *k.Capability == "agent-host" {
		return "bromure-account:machine:" + k.ID
	}
	return "bromure-account:" + k.ID
}

// HTTPError is a non-2xx answer; Code is the body's {"error": …}.
type HTTPError struct {
	Status int
	Code   string
}

func (e *HTTPError) Error() string {
	if e.Code != "" {
		return fmt.Sprintf("bromure.io: HTTP %d (%s)", e.Status, e.Code)
	}
	return fmt.Sprintf("bromure.io: HTTP %d", e.Status)
}

var (
	ErrDecode          = errors.New("bromure.io: unexpected response")
	ErrTurnUnavailable = errors.New("bromure.io: TURN unavailable")
)

// Endpoint is the control-plane base URL.
type Endpoint struct{ Base *url.URL }

// NewEndpoint normalizes base: a bare https://bromure.io becomes
// https://bromure.io/api; one with a path, or a local dev host, is kept.
func NewEndpoint(base string) (Endpoint, error) {
	s := strings.TrimSpace(base)
	for strings.HasSuffix(s, "/") {
		s = s[:len(s)-1]
	}
	u, err := url.Parse(s)
	if err != nil || u.Host == "" || u.Scheme == "" {
		return Endpoint{}, fmt.Errorf("bad control-plane base %q", base)
	}
	host := u.Hostname()
	local := host == "localhost" || host == "127.0.0.1" || strings.HasSuffix(host, ".local")
	if (u.Path == "" || u.Path == "/") && !local {
		u.Path = "/api"
	}
	return Endpoint{u}, nil
}

// String is the base as text (what a device record keeps as apiBase).
func (e Endpoint) String() string { return e.Base.String() }

// URL joins path onto the base (appendingPathComponent).
func (e Endpoint) URL(path string) string {
	u := *e.Base
	u.Path = strings.TrimSuffix(u.Path, "/") + "/" + strings.TrimPrefix(path, "/")
	u.RawPath = ""
	return u.String()
}

// DeviceChannelURL is wss://…/v1/device-channel (ws:// for an http base).
func (e Endpoint) DeviceChannelURL() string {
	u, _ := url.Parse(e.URL("/v1/device-channel"))
	if e.Base.Scheme == "http" {
		u.Scheme = "ws"
	} else {
		u.Scheme = "wss"
	}
	return u.String()
}

// Client is the stateless REST client.
type Client struct {
	Endpoint Endpoint
	HTTP     *http.Client
}

// New is a client with a 20 s request timeout.
func New(ep Endpoint) *Client {
	return &Client{Endpoint: ep, HTTP: &http.Client{Timeout: 20 * time.Second}}
}

// EnrollBegin is phase 1 (no bearer). deviceName/capability are optional.
func (c *Client) EnrollBegin(ctx context.Context, code, devicePubkeyHex string, deviceName, capability *string) (EnrollBeginResponse, error) {
	body := struct {
		Code         string  `json:"code"`
		DevicePubkey string  `json:"devicePubkey"`
		DeviceName   *string `json:"deviceName,omitempty"`
		Capability   *string `json:"capability,omitempty"`
	}{code, devicePubkeyHex, deviceName, capability}
	var out EnrollBeginResponse
	return out, c.do(ctx, "POST", "/v1/devices/enroll", body, "", &out)
}

// EnrollComplete is phase 2.
func (c *Client) EnrollComplete(ctx context.Context, challengeID, signatureB64 string) (EnrollCompleteResponse, error) {
	body := struct {
		ChallengeID string `json:"challengeId"`
		Signature   string `json:"signature"`
	}{challengeID, signatureB64}
	var out EnrollCompleteResponse
	return out, c.do(ctx, "POST", "/v1/devices/enroll", body, "", &out)
}

// ListDevices is GET /v1/devices.
func (c *Client) ListDevices(ctx context.Context, bearer string) ([]DeviceInfo, error) {
	var w struct {
		Devices *[]DeviceInfo `json:"devices"`
	}
	if err := c.do(ctx, "GET", "/v1/devices", nil, bearer, &w); err != nil {
		return nil, err
	}
	if w.Devices == nil {
		return nil, ErrDecode
	}
	return *w.Devices, nil
}

// RequestConnection is POST /v1/connections (a 45 s grant to deviceID).
func (c *Client) RequestConnection(ctx context.Context, bearer, deviceID string) (signal.ConnectionGrant, error) {
	var w struct {
		Connection *signal.ConnectionGrant `json:"connection"`
	}
	if err := c.do(ctx, "POST", "/v1/connections", map[string]string{"deviceId": deviceID}, bearer, &w); err != nil {
		return signal.ConnectionGrant{}, err
	}
	if w.Connection == nil {
		return signal.ConnectionGrant{}, ErrDecode
	}
	return *w.Connection, nil
}

// SetServerMode turns the p2p_server flag on/off; the resulting state.
func (c *Client) SetServerMode(ctx context.Context, bearer string, enabled bool) (bool, error) {
	var w struct {
		OK     bool `json:"ok"`
		Server bool `json:"server"`
	}
	err := c.do(ctx, "POST", "/v1/devices/server-mode", map[string]bool{"enabled": enabled}, bearer, &w)
	return w.Server, err
}

// TurnCredentials mints the grant's TURN REST credentials (503 →
// ErrTurnUnavailable).
func (c *Client) TurnCredentials(ctx context.Context, bearer, connectionID string) (TurnCredentials, error) {
	var w struct {
		Turn *TurnCredentials `json:"turn"`
	}
	err := c.do(ctx, "POST", "/v1/connections/"+connectionID+"/turn-credentials", struct{}{}, bearer, &w)
	var he *HTTPError
	if errors.As(err, &he) && he.Status == 503 {
		return TurnCredentials{}, ErrTurnUnavailable
	}
	if err != nil {
		return TurnCredentials{}, err
	}
	if w.Turn == nil || w.Turn.URLs == nil {
		return TurnCredentials{}, ErrDecode
	}
	return *w.Turn, nil
}

// Complete posts the telemetry report; whether it was recorded.
func (c *Client) Complete(ctx context.Context, bearer, connectionID string, r ConnectionReport) (bool, error) {
	var w struct {
		OK       bool `json:"ok"`
		Recorded bool `json:"recorded"`
	}
	err := c.do(ctx, "POST", "/v1/connections/"+connectionID+"/complete", r, bearer, &w)
	return w.Recorded, err
}

// UploadSSHKey publishes this device's OpenSSH ed25519 line and login.
func (c *Client) UploadSSHKey(ctx context.Context, bearer, sshPublicKey, sshUsername string) error {
	body := struct {
		SSHPublicKey string `json:"sshPublicKey"`
		SSHUsername  string `json:"sshUsername"`
	}{sshPublicKey, sshUsername}
	return c.do(ctx, "POST", "/v1/devices/ssh-key", body, bearer, &struct{}{})
}

// RemoveSSHKey withdraws this device's SSH key.
func (c *Client) RemoveSSHKey(ctx context.Context, bearer string) error {
	return c.do(ctx, "DELETE", "/v1/devices/ssh-key", nil, bearer, &struct{}{})
}

// SelfRevoke retires this device.
func (c *Client) SelfRevoke(ctx context.Context, bearer string) error {
	return c.do(ctx, "POST", "/v1/devices/self-revoke", struct{}{}, bearer, &struct{}{})
}

// ListSSHKeys is the caller's own devices' SSH keys.
func (c *Client) ListSSHKeys(ctx context.Context, bearer string) ([]DeviceSSHKey, error) {
	var w struct {
		Keys *[]DeviceSSHKey `json:"keys"`
	}
	if err := c.do(ctx, "GET", "/v1/devices/ssh-keys", nil, bearer, &w); err != nil {
		return nil, err
	}
	if w.Keys == nil {
		return nil, ErrDecode
	}
	return *w.Keys, nil
}

func (c *Client) do(ctx context.Context, method, path string, body any, bearer string, out any) error {
	var rd io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rd = bytes.NewReader(data)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.Endpoint.URL(path), rd)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	hc := c.HTTP
	if hc == nil {
		hc = &http.Client{Timeout: 20 * time.Second}
	}
	resp, err := hc.Do(req)
	if err != nil {
		return fmt.Errorf("bromure.io: %w", err)
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return fmt.Errorf("bromure.io: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		var e struct {
			Error string `json:"error"`
		}
		_ = json.Unmarshal(data, &e)
		return &HTTPError{Status: resp.StatusCode, Code: e.Error}
	}
	if json.Unmarshal(data, out) != nil {
		return ErrDecode
	}
	return nil
}
