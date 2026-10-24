// Package cptest is a fake bromure.io control plane for tests (httptest):
// devices with bearer tokens, server mode, /v1/connections grants pushed to
// the target's device channel, the signaling relay, TURN credentials from a
// fake relay, telemetry, SSH-key publish/list, the device directory and the
// two-phase enroll. Never talks to the real bromure.io.
package cptest

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// Device is one enrolled device.
type Device struct {
	ID          string
	Token       string
	Name        string
	Capability  string
	SSHKey      string
	SSHUsername string
	Server      bool
	Revoked     bool
	// ForceOnline lists it online without a channel.
	ForceOnline bool
}

// Server is the fake control plane.
type Server struct {
	*httptest.Server
	// TurnURLs, TurnUser, TurnPass answer turn-credentials.
	TurnURLs           []string
	TurnUser, TurnPass string
	// EnrollCapability is what an enroll code grants.
	EnrollCapability string

	mu         sync.Mutex
	devices    map[string]*Device // by token
	chans      map[string]*websocket.Conn
	grants     map[string]*grant
	nextGrant  int
	Completed  []string // connection ids reported complete
	challenges map[string]string
	pubkeys    map[string]string
}

type grant struct {
	id             string
	client, server *Device
	sigClient      string
	sigServer      string
}

// New starts the fake.
func New() *Server {
	s := &Server{devices: map[string]*Device{}, chans: map[string]*websocket.Conn{}, grants: map[string]*grant{},
		challenges: map[string]string{}, pubkeys: map[string]string{}, EnrollCapability: "agent-host"}
	s.Server = httptest.NewServer(http.HandlerFunc(s.handle))
	return s
}

// AddDevice registers a device.
func (s *Server) AddDevice(d *Device) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.devices[d.Token] = d
}

// Device returns a device by id.
func (s *Server) Device(id string) *Device {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, d := range s.devices {
		if d.ID == id {
			return d
		}
	}
	return nil
}

// CompletedIDs is the connection ids reported complete so far.
func (s *Server) CompletedIDs() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.Completed...)
}

// Online reports whether a device holds a channel.
func (s *Server) Online(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, ok := s.chans[id]
	return ok
}

// Push sends a raw frame to a device's channel.
func (s *Server) Push(id string, frame any) {
	s.mu.Lock()
	c := s.chans[id]
	s.mu.Unlock()
	if c != nil {
		data, _ := json.Marshal(frame)
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = c.Write(ctx, websocket.MessageText, data)
	}
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func (s *Server) auth(r *http.Request) *Device {
	tok := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	s.mu.Lock()
	defer s.mu.Unlock()
	d := s.devices[tok]
	if d == nil || d.Revoked {
		return nil
	}
	return d
}

func peerView(d *Device, sig, role string) map[string]string {
	return map[string]string{"deviceId": d.ID, "signalId": sig, "role": role}
}

func (s *Server) handle(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	if path == "/v1/devices/enroll" {
		s.enroll(w, r)
		return
	}
	d := s.auth(r)
	if d == nil {
		writeJSON(w, 401, map[string]string{"error": "unauthorized"})
		return
	}
	var body map[string]any
	if r.Body != nil {
		_ = json.NewDecoder(r.Body).Decode(&body)
	}
	switch {
	case path == "/v1/device-channel":
		s.channel(w, r, d)
	case path == "/v1/devices/server-mode":
		on, _ := body["enabled"].(bool)
		s.mu.Lock()
		d.Server = on
		s.mu.Unlock()
		writeJSON(w, 200, map[string]any{"ok": true, "server": on})
	case path == "/v1/devices" && r.Method == "GET":
		s.mu.Lock()
		var rows []map[string]any
		for _, x := range s.devices {
			_, online := s.chans[x.ID]
			online = online || x.ForceOnline
			rows = append(rows, map[string]any{"id": x.ID, "name": x.Name, "capability": x.Capability,
				"revoked": x.Revoked, "online": online, "lastSeenAt": nil, "self": x == d, "sshUsername": x.SSHUsername})
		}
		s.mu.Unlock()
		writeJSON(w, 200, map[string]any{"devices": rows})
	case path == "/v1/devices/ssh-key" && r.Method == "POST":
		s.mu.Lock()
		d.SSHKey, _ = body["sshPublicKey"].(string)
		d.SSHUsername, _ = body["sshUsername"].(string)
		s.mu.Unlock()
		writeJSON(w, 200, map[string]any{"ok": true})
	case path == "/v1/devices/ssh-keys":
		s.mu.Lock()
		var keys []map[string]any
		for _, x := range s.devices {
			if x.SSHKey != "" {
				keys = append(keys, map[string]any{"id": x.ID, "name": x.Name, "sshPublicKey": x.SSHKey, "capability": x.Capability})
			}
		}
		s.mu.Unlock()
		writeJSON(w, 200, map[string]any{"keys": keys})
	case path == "/v1/connections" && r.Method == "POST":
		target, _ := body["deviceId"].(string)
		srv := s.Device(target)
		if srv == nil || !s.Online(target) {
			writeJSON(w, 409, map[string]string{"error": "peer_offline"})
			return
		}
		s.mu.Lock()
		s.nextGrant++
		g := &grant{id: "conn-" + strconv.Itoa(s.nextGrant), client: d, server: srv,
			sigClient: "sig-c-" + strconv.Itoa(s.nextGrant), sigServer: "sig-s-" + strconv.Itoa(s.nextGrant)}
		s.grants[g.id] = g
		s.mu.Unlock()
		exp := time.Now().Add(45 * time.Second).UTC().Format(time.RFC3339)
		s.Push(srv.ID, map[string]any{"type": "connection", "connection": map[string]any{"id": g.id, "expiresAt": exp,
			"self": peerView(srv, g.sigServer, "server"), "peer": peerView(d, g.sigClient, "client")}})
		writeJSON(w, 200, map[string]any{"connection": map[string]any{"id": g.id, "expiresAt": exp,
			"self": peerView(d, g.sigClient, "client"), "peer": peerView(srv, g.sigServer, "server")}})
	case strings.HasSuffix(path, "/turn-credentials"):
		if len(s.TurnURLs) == 0 {
			writeJSON(w, 503, map[string]string{"error": "turn_unavailable"})
			return
		}
		writeJSON(w, 200, map[string]any{"turn": map[string]any{"urls": s.TurnURLs, "username": s.TurnUser,
			"credential": s.TurnPass, "ttlSeconds": 3600, "expiresAt": "2030-01-01T00:00:00Z", "region": "test"}})
	case strings.HasSuffix(path, "/complete"):
		id := strings.TrimSuffix(strings.TrimPrefix(path, "/v1/connections/"), "/complete")
		s.mu.Lock()
		s.Completed = append(s.Completed, id)
		s.mu.Unlock()
		writeJSON(w, 200, map[string]any{"ok": true, "recorded": true})
	default:
		writeJSON(w, 404, map[string]string{"error": "not_found"})
	}
}

func (s *Server) channel(w http.ResponseWriter, r *http.Request, d *Device) {
	c, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	s.mu.Lock()
	s.chans[d.ID] = c
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		if s.chans[d.ID] == c {
			delete(s.chans, d.ID)
		}
		s.mu.Unlock()
		c.CloseNow()
	}()
	for {
		_, data, err := c.Read(context.Background())
		if err != nil {
			return
		}
		var f struct {
			ConnectionID string          `json:"connectionId"`
			Seq          int             `json:"seq"`
			Kind         string          `json:"kind"`
			Payload      json.RawMessage `json:"payload"`
		}
		if json.Unmarshal(data, &f) != nil {
			continue
		}
		s.mu.Lock()
		g := s.grants[f.ConnectionID]
		s.mu.Unlock()
		if g == nil {
			s.Push(d.ID, map[string]any{"type": "error", "error": "unknown_connection", "connectionId": f.ConnectionID})
			continue
		}
		to, from := g.server, g.sigClient
		if d == g.server {
			to, from = g.client, g.sigServer
		}
		s.Push(to.ID, map[string]any{"type": "signal", "connectionId": f.ConnectionID, "seq": f.Seq,
			"kind": f.Kind, "from": from, "payload": f.Payload})
	}
}

// enroll is the two-phase key-possession proof; any code is accepted and
// enrolls a new device "dev-enrolled-N".
func (s *Server) enroll(w http.ResponseWriter, r *http.Request) {
	var body map[string]any
	_ = json.NewDecoder(r.Body).Decode(&body)
	if _, ok := body["code"]; ok {
		s.mu.Lock()
		id := "ch-" + strconv.Itoa(len(s.challenges)+1)
		s.challenges[id] = "bromure-p2p-enroll:v1:" + id + ":Y2hhbGxlbmdl"
		s.pubkeys[id], _ = body["devicePubkey"].(string)
		payload := s.challenges[id]
		s.mu.Unlock()
		writeJSON(w, 200, map[string]any{"challengeId": id, "challenge": "Y2hhbGxlbmdl", "signPayload": payload,
			"capability": s.EnrollCapability, "expiresInSeconds": 120})
		return
	}
	id, _ := body["challengeId"].(string)
	sigB64, _ := body["signature"].(string)
	s.mu.Lock()
	payload, pubHex := s.challenges[id], s.pubkeys[id]
	s.mu.Unlock()
	pub, _ := hex.DecodeString(pubHex)
	sig, _ := base64.StdEncoding.DecodeString(sigB64)
	if payload == "" || len(pub) != ed25519.PublicKeySize || !ed25519.Verify(pub, []byte(payload), sig) {
		writeJSON(w, 401, map[string]string{"error": "bad_signature"})
		return
	}
	s.mu.Lock()
	n := len(s.devices) + 1
	dev := &Device{ID: "dev-enrolled-" + strconv.Itoa(n), Token: "tok-enrolled-" + strconv.Itoa(n), Capability: s.EnrollCapability}
	s.devices[dev.Token] = dev
	s.mu.Unlock()
	writeJSON(w, 200, map[string]any{"deviceId": dev.ID, "deviceToken": dev.Token, "deviceTokenExpiresAt": nil,
		"capability": dev.Capability, "orgSlug": nil, "orgKind": "individual", "userId": "user-1"})
}
