// Package signal is the P2P signaling wire model, ported from
// Sources/AgentCoding/P2P/{P2PCandidate,P2PSignaling}.swift and the
// ConnectionGrant DTO of ControlPlaneClient.swift.
//
// JSON is emitted in the Swift structs' declaration order with nil
// optionals omitted (what Swift's synthesized Codable + JSONEncoder does);
// the control plane relays the payload verbatim and never parses it.
package signal

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

// Candidate kinds.
const (
	KindHost       = "host"
	KindSrflx      = "srflx"
	KindPortMapped = "port-mapped"
	KindRelay      = "relay"
)

// Candidate protocols.
const (
	ProtoUDP = "udp"
	ProtoTCP = "tcp"
)

// Candidate is one reachable-endpoint hypothesis (P2PCandidate).
type Candidate struct {
	Kind  string `json:"kind"`
	Proto string `json:"proto"`
	IP    string `json:"ip"`
	Port  int    `json:"port"`
	Prio  int    `json:"prio"`
	TTL   *int   `json:"ttl,omitempty"`
}

// NewCandidate fills Prio with DefaultPriority, as the Swift init does.
func NewCandidate(kind, proto, ip string, port int, ttl *int) Candidate {
	return Candidate{Kind: kind, Proto: proto, IP: ip, Port: port, Prio: DefaultPriority(kind, proto, ip), TTL: ttl}
}

// Key identifies a candidate for de-duplication (Swift Equatable/Hashable
// compares every field, ttl included).
func (c Candidate) Key() string {
	ttl := "-"
	if c.TTL != nil {
		ttl = strconv.Itoa(*c.TTL)
	}
	return c.Kind + "|" + c.Proto + "|" + c.IP + "|" + strconv.Itoa(c.Port) + "|" + strconv.Itoa(c.Prio) + "|" + ttl
}

// DefaultPriority: type first (host > port-mapped > srflx > relay), then the
// kind-aware proto preference, then a slight IPv6 nudge.
func DefaultPriority(kind, proto, ip string) int {
	var typePref int
	switch kind {
	case KindHost:
		typePref = 126
	case KindPortMapped:
		typePref = 110
	case KindSrflx:
		typePref = 100
	default:
		typePref = 0
	}
	var protoPref int
	if kind == KindRelay {
		protoPref = 1
		if proto == ProtoUDP {
			protoPref = 2
		}
	} else {
		protoPref = 1
		if proto == ProtoTCP {
			protoPref = 2
		}
	}
	fam := 0
	if strings.Contains(ip, ":") {
		fam = 1
	}
	return typePref<<16 | protoPref<<8 | fam<<4
}

// Payload is the body inside a signaling frame (P2PSignalPayload).
// Candidates nil = absent; an empty non-nil slice encodes as [] (the
// relay-only answer is {"v":1,"candidates":[]}).
type Payload struct {
	V          int
	Candidates []Candidate
	Candidate  *Candidate
	Note       *string
}

// NewPayload is a v1 payload.
func NewPayload() Payload { return Payload{V: 1} }

// WithNote is a v1 payload carrying only a note ("connect").
func WithNote(note string) Payload { return Payload{V: 1, Note: &note} }

// WithCandidate is a v1 trickle payload.
func WithCandidate(c Candidate) Payload { return Payload{V: 1, Candidate: &c} }

// WithCandidates is a v1 bulk payload (an empty list stays []).
func WithCandidates(cs []Candidate) Payload {
	if cs == nil {
		cs = []Candidate{}
	}
	return Payload{V: 1, Candidates: cs}
}

// All is bulk + single, in one list.
func (p Payload) All() []Candidate {
	out := append([]Candidate(nil), p.Candidates...)
	if p.Candidate != nil {
		out = append(out, *p.Candidate)
	}
	return out
}

// MarshalJSON writes v, candidates, candidate, note in that order.
func (p Payload) MarshalJSON() ([]byte, error) {
	var b bytes.Buffer
	fmt.Fprintf(&b, `{"v":%d`, p.V)
	if p.Candidates != nil {
		c, err := json.Marshal(p.Candidates)
		if err != nil {
			return nil, err
		}
		b.WriteString(`,"candidates":`)
		b.Write(c)
	}
	if p.Candidate != nil {
		c, err := json.Marshal(p.Candidate)
		if err != nil {
			return nil, err
		}
		b.WriteString(`,"candidate":`)
		b.Write(c)
	}
	if p.Note != nil {
		n, err := json.Marshal(*p.Note)
		if err != nil {
			return nil, err
		}
		b.WriteString(`,"note":`)
		b.Write(n)
	}
	b.WriteByte('}')
	return b.Bytes(), nil
}

// UnmarshalJSON is strict like Swift's decoder on present fields: a
// candidate of the wrong shape fails the payload.
func (p *Payload) UnmarshalJSON(data []byte) error {
	var raw struct {
		V          *int        `json:"v"`
		Candidates []Candidate `json:"candidates"`
		Candidate  *Candidate  `json:"candidate"`
		Note       *string     `json:"note"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	*p = Payload{V: 1, Candidates: raw.Candidates, Candidate: raw.Candidate, Note: raw.Note}
	if raw.V != nil {
		p.V = *raw.V
	}
	return nil
}

// Signal kinds (the gateway rejects any other).
const (
	KindOffer     = "offer"
	KindAnswer    = "answer"
	KindCandidate = "candidate"
)

// MaxFrameBytes is the gateway's MAX_FRAME_BYTES.
const MaxFrameBytes = 4096

// OutgoingFrame is a client → server signaling frame.
type OutgoingFrame struct {
	ConnectionID string  `json:"connectionId"`
	Seq          int     `json:"seq"`
	Kind         string  `json:"kind"`
	Payload      Payload `json:"payload"`
}

// ErrFrameTooLarge is returned for a frame over MaxFrameBytes.
type ErrFrameTooLarge struct{ Size int }

func (e ErrFrameTooLarge) Error() string {
	return fmt.Sprintf("signal frame too large (%d bytes)", e.Size)
}

// Encode is the JSON text for the WebSocket message.
func (f OutgoingFrame) Encode() ([]byte, error) {
	data, err := json.Marshal(f)
	if err != nil {
		return nil, err
	}
	if len(data) > MaxFrameBytes {
		return nil, ErrFrameTooLarge{len(data)}
	}
	return data, nil
}

// GrantPeer is one peer's session-scoped identity within a grant.
type GrantPeer struct {
	DeviceID string `json:"deviceId"`
	SignalID string `json:"signalId"`
	Role     string `json:"role"`
}

// ConnectionGrant is POST /v1/connections' grant (45 s TTL), also pushed to
// the server device as a `connection` frame.
type ConnectionGrant struct {
	ID        string    `json:"id"`
	ExpiresAt string    `json:"expiresAt"`
	Self      GrantPeer `json:"self"`
	Peer      GrantPeer `json:"peer"`
}

// Incoming frame types.
const (
	FrameSignal      = "signal"
	FrameConnection  = "connection"
	FrameError       = "error"
	FrameKeysChanged = "keys-changed"
)

// IncomingFrame is a decoded server → client frame. Type is one of the
// Frame* constants, or "unknown" (with Raw holding the server's type).
type IncomingFrame struct {
	Type         string
	RawType      string
	ConnectionID string
	Seq          int
	Kind         string
	From         string
	Payload      Payload
	Grant        ConnectionGrant
	ErrorCode    string
	HasConnID    bool
}

// DecodeIncoming parses one text frame; ok=false only when it isn't a JSON
// object with a string `type`.
func DecodeIncoming(data []byte) (IncomingFrame, bool) {
	var obj map[string]json.RawMessage
	if json.Unmarshal(data, &obj) != nil {
		return IncomingFrame{}, false
	}
	var typ string
	if json.Unmarshal(obj["type"], &typ) != nil {
		return IncomingFrame{}, false
	}
	unknown := IncomingFrame{Type: "unknown", RawType: typ}
	str := func(k string) (string, bool) {
		var s string
		if v, ok := obj[k]; ok && json.Unmarshal(v, &s) == nil {
			return s, true
		}
		return "", false
	}
	switch typ {
	case FrameSignal:
		connID, ok1 := str("connectionId")
		kindRaw, ok2 := str("kind")
		from, ok3 := str("from")
		var seqF float64
		seqOK := json.Unmarshal(obj["seq"], &seqF) == nil && seqF == float64(int(seqF))
		if !ok1 || !ok2 || !ok3 || !seqOK {
			return unknown, true
		}
		switch kindRaw {
		case KindOffer, KindAnswer, KindCandidate:
		default:
			return unknown, true
		}
		var p Payload
		if raw, ok := obj["payload"]; !ok || json.Unmarshal(raw, &p) != nil || !isObject(raw) {
			p = NewPayload()
		}
		return IncomingFrame{Type: FrameSignal, RawType: typ, ConnectionID: connID, Seq: int(seqF),
			Kind: kindRaw, From: from, Payload: p}, true
	case FrameConnection:
		var g ConnectionGrant
		raw, ok := obj["connection"]
		if !ok || !isObject(raw) || json.Unmarshal(raw, &g) != nil || !grantComplete(raw) {
			return unknown, true
		}
		return IncomingFrame{Type: FrameConnection, RawType: typ, Grant: g}, true
	case FrameError:
		code, ok := str("error")
		if !ok {
			code = "unknown"
		}
		connID, has := str("connectionId")
		return IncomingFrame{Type: FrameError, RawType: typ, ErrorCode: code, ConnectionID: connID, HasConnID: has}, true
	case FrameKeysChanged:
		return IncomingFrame{Type: FrameKeysChanged, RawType: typ}, true
	}
	return unknown, true
}

func isObject(raw json.RawMessage) bool {
	t := bytes.TrimSpace(raw)
	return len(t) > 0 && t[0] == '{'
}

// grantComplete: Swift's decoder requires every grant field.
func grantComplete(raw json.RawMessage) bool {
	var g struct {
		ID        *string                     `json:"id"`
		ExpiresAt *string                     `json:"expiresAt"`
		Self      map[string]*json.RawMessage `json:"self"`
		Peer      map[string]*json.RawMessage `json:"peer"`
	}
	if json.Unmarshal(raw, &g) != nil || g.ID == nil || g.ExpiresAt == nil {
		return false
	}
	for _, p := range []map[string]*json.RawMessage{g.Self, g.Peer} {
		for _, k := range []string{"deviceId", "signalId", "role"} {
			if p[k] == nil {
				return false
			}
		}
	}
	return true
}
