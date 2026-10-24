// Package identity is the Sidecar's bromure.io device identity: the device
// record file (DeviceIdentity.swift, AGENT_HOST variant: an owner-only JSON
// file, same shape as the Swift's so a record is portable), the Ed25519
// device key, the enroll link parser and the two-phase enrollment
// (P2PEnroll.swift), and the resolved identity (P2PIdentity.swift; the
// enterprise fallback is always empty here, as in the Swift Sidecar).
package identity

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode"

	"github.com/rderaison/bromure/sidecar/internal/p2p/controlplane"
	"github.com/rderaison/bromure/sidecar/internal/paths"
)

// referenceDate is Foundation's Date reference (2001-01-01T00:00:00Z):
// Swift's JSONEncoder writes a Date as seconds since it.
var referenceDate = time.Date(2001, 1, 1, 0, 0, 0, 0, time.UTC)

// SwiftDate is a time that round-trips through Swift's default Date coding.
type SwiftDate struct{ time.Time }

func (d SwiftDate) MarshalJSON() ([]byte, error) {
	secs := float64(d.Sub(referenceDate)) / float64(time.Second)
	return json.Marshal(secs)
}

func (d *SwiftDate) UnmarshalJSON(b []byte) error {
	var secs float64
	if err := json.Unmarshal(b, &secs); err == nil {
		whole, frac := math.Modf(secs)
		d.Time = referenceDate.Add(time.Duration(whole) * time.Second).Add(time.Duration(frac * float64(time.Second)))
		return nil
	}
	// Tolerate an ISO-8601 string (a hand-written record).
	var s string
	if err := json.Unmarshal(b, &s); err != nil {
		return err
	}
	t, ok := ParseISO8601(s)
	if !ok {
		return fmt.Errorf("bad date %q", s)
	}
	d.Time = t
	return nil
}

// ParseISO8601 accepts internet date-time with or without fractional seconds.
func ParseISO8601(s string) (time.Time, bool) {
	for _, layout := range []string{"2006-01-02T15:04:05.999999999Z07:00", time.RFC3339} {
		if t, err := time.Parse(layout, s); err == nil {
			return t, true
		}
	}
	return time.Time{}, false
}

// Record is one install's control-plane identity (DeviceRecord).
type Record struct {
	PrivateKeyHex        string     `json:"privateKeyHex"` // Ed25519 seed, 64 hex chars
	DeviceToken          string     `json:"deviceToken"`
	DeviceTokenExpiresAt *SwiftDate `json:"deviceTokenExpiresAt,omitempty"`
	DeviceID             string     `json:"deviceId"`
	Capability           string     `json:"capability"`
	OrgSlug              *string    `json:"orgSlug,omitempty"`
	OrgKind              *string    `json:"orgKind,omitempty"`
	APIBase              string     `json:"apiBase"`
}

// RecordsSessionTelemetry: only confirmed organization workspaces report.
func (r Record) RecordsSessionTelemetry() bool {
	return r.OrgKind != nil && *r.OrgKind == "organization"
}

// LoadResult is the three honest outcomes of reading the record.
type LoadResult int

const (
	Found LoadResult = iota
	NotEnrolled
	Unavailable // present but unreadable / undecodable: never "not enrolled"
)

// Path is where the record lives (tests may point it elsewhere).
var Path = paths.DeviceRecord

// Load reads the record.
func Load() (Record, LoadResult) {
	data, err := os.ReadFile(Path())
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return Record{}, NotEnrolled
		}
		return Record{}, Unavailable
	}
	var r Record
	if json.Unmarshal(data, &r) != nil {
		return Record{}, Unavailable
	}
	return r, Found
}

// Store writes the record owner-only and reads it back.
func Store(r Record) error {
	data, err := json.Marshal(r)
	if err != nil {
		return err
	}
	p := Path()
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return err
	}
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	_ = paths.ProtectFile(tmp)
	if err := os.Rename(tmp, p); err != nil {
		return err
	}
	back, err := os.ReadFile(p)
	if err != nil || !bytes.Equal(back, data) {
		return errors.New("device record didn't read back")
	}
	return nil
}

// Erase forgets the record.
func Erase() { _ = os.Remove(Path()) }

// Identity is the resolved control-plane identity (P2PIdentity).
type Identity struct {
	APIBase   string
	Bearer    string
	InstallID string
	OrgSlug   string
	OrgKind   string
	Record    Record
}

// RecordsSessionTelemetry: personal accounts record nothing.
func (i Identity) RecordsSessionTelemetry() bool { return i.OrgKind == "organization" }

// Current is the device-record identity, or false. An unreadable record is
// not enrolled-as-someone-else: still false, never a fallback.
func Current() (Identity, bool) {
	r, res := Load()
	if res != Found {
		return Identity{}, false
	}
	id := Identity{APIBase: r.APIBase, Bearer: r.DeviceToken, InstallID: r.DeviceID, Record: r}
	if r.OrgSlug != nil {
		id.OrgSlug = *r.OrgSlug
	}
	if r.OrgKind != nil {
		id.OrgKind = *r.OrgKind
	}
	return id, true
}

// SigningKey is the device's Ed25519 key with the control plane's encodings.
type SigningKey struct{ priv ed25519.PrivateKey }

// NewSigningKey generates a key.
func NewSigningKey() SigningKey {
	seed := make([]byte, ed25519.SeedSize)
	_, _ = rand.Read(seed)
	return SigningKey{ed25519.NewKeyFromSeed(seed)}
}

// SigningKeyFromHex loads a raw 32-byte seed in hex.
func SigningKeyFromHex(h string) (SigningKey, error) {
	seed, err := hex.DecodeString(h)
	if err != nil || len(seed) != ed25519.SeedSize {
		return SigningKey{}, errors.New("bad Ed25519 seed")
	}
	return SigningKey{ed25519.NewKeyFromSeed(seed)}, nil
}

// PrivateKeyHex is the seed, lower-case hex.
func (k SigningKey) PrivateKeyHex() string { return hex.EncodeToString(k.priv.Seed()) }

// PublicKeyHex is the raw 32-byte public key, lower-case hex (devicePubkey).
func (k SigningKey) PublicKeyHex() string {
	return hex.EncodeToString(k.priv.Public().(ed25519.PublicKey))
}

// SignBase64 is the Ed25519 signature over payload's UTF-8 bytes, standard
// base64 (not base64url): the enroll phase 2 `signature`.
func (k SigningKey) SignBase64(payload string) string {
	return base64.StdEncoding.EncodeToString(ed25519.Sign(k.priv, []byte(payload)))
}

// DefaultAPIBase is the control plane when a code carries no `api`.
const DefaultAPIBase = "https://bromure.io/api"

// Link is a parsed enrollment code + API base (EnrollLink).
type Link struct {
	Code    string
	APIBase string
}

// queryItems splits a raw query the way URLComponents.queryItems does:
// percent-decoded, '+' kept literal, first occurrence wins in lookups.
func queryItems(raw string) [][2]string {
	var out [][2]string
	if raw == "" {
		return out
	}
	for _, pair := range strings.Split(raw, "&") {
		k, v, hasV := strings.Cut(pair, "=")
		dk, err1 := url.PathUnescape(k)
		dv, err2 := url.PathUnescape(v)
		if err1 != nil {
			dk = k
		}
		if err2 != nil {
			dv = v
		}
		if !hasV {
			dv = ""
		}
		out = append(out, [2]string{dk, dv})
	}
	return out
}

// QueryValue is the first value named name in a URL's query, or false.
func QueryValue(raw, name string) (string, bool) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return "", false
	}
	for _, kv := range queryItems(u.RawQuery) {
		if kv[0] == name {
			return kv[1], true
		}
	}
	return "", false
}

// ParseLink accepts a `bromure://enroll?…` / `bromure-agent-host://enroll?…`
// deep link, an https link with `code` (and `api`), or a bare code.
func ParseLink(raw string) (Link, bool) {
	s := strings.TrimSpace(raw)
	if s == "" {
		return Link{}, false
	}
	if strings.Contains(s, "://") {
		u, err := url.Parse(s)
		if err != nil {
			return Link{}, false
		}
		host := strings.ToLower(u.Hostname())
		path := strings.ToLower(u.Path)
		if host == "enroll" || strings.Contains(path, "enroll") || u.Scheme == "bromure" {
			var code, api string
			var haveCode, haveAPI bool
			for _, kv := range queryItems(u.RawQuery) {
				if kv[0] == "code" && !haveCode {
					code, haveCode = kv[1], true
				}
				if kv[0] == "api" && !haveAPI {
					api, haveAPI = kv[1], true
				}
			}
			if code != "" {
				if api == "" {
					api = DefaultAPIBase
				}
				return Link{code, api}, true
			}
		}
		return Link{}, false
	}
	if len([]rune(s)) < 16 {
		return Link{}, false
	}
	for _, r := range s {
		if !(unicode.IsLetter(r) || unicode.IsNumber(r) || r == '-' || r == '_') {
			return Link{}, false
		}
	}
	return Link{s, DefaultAPIBase}, true
}

// Enroll runs the two-phase key-possession proof against link and stores
// the record. deviceName and capability are optional (the Swift Sidecar
// passes its machine name and no capability: the code carries it).
func Enroll(ctx context.Context, link Link, deviceName, capability *string, hc *controlplane.Client) (Record, error) {
	ep, err := controlplane.NewEndpoint(link.APIBase)
	if err != nil {
		return Record{}, err
	}
	client := hc
	if client == nil {
		client = controlplane.New(ep)
	} else {
		client = &controlplane.Client{Endpoint: ep, HTTP: hc.HTTP}
	}
	key := NewSigningKey()
	begin, err := client.EnrollBegin(ctx, link.Code, key.PublicKeyHex(), deviceName, capability)
	if err != nil {
		return Record{}, err
	}
	done, err := client.EnrollComplete(ctx, begin.ChallengeID, key.SignBase64(begin.SignPayload))
	if err != nil {
		return Record{}, err
	}
	rec := Record{PrivateKeyHex: key.PrivateKeyHex(), DeviceToken: done.DeviceToken, DeviceID: done.DeviceID,
		Capability: done.Capability, OrgSlug: done.OrgSlug, OrgKind: done.OrgKind, APIBase: ep.String()}
	if done.DeviceTokenExpiresAt != nil {
		if t, ok := ParseISO8601(*done.DeviceTokenExpiresAt); ok {
			rec.DeviceTokenExpiresAt = &SwiftDate{t}
		}
	}
	if err := Store(rec); err != nil {
		return Record{}, err
	}
	return rec, nil
}
