package identity

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/paths"
)

func kv(t *testing.T, name string) map[string]string {
	data, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]string{}
	for _, l := range strings.Split(string(data), "\n") {
		l = strings.TrimRight(l, "\r")
		if l == "" || strings.HasPrefix(l, "#") {
			continue
		}
		k, v, _ := strings.Cut(l, "\t")
		out[k] = v
	}
	return out
}

func TestGoldenEnrollSignature(t *testing.T) {
	f := kv(t, "enroll_sign.txt")
	k, err := SigningKeyFromHex(f["seed"])
	if err != nil {
		t.Fatal(err)
	}
	if k.PublicKeyHex() != f["pubkey"] {
		t.Fatalf("pubkey %s", k.PublicKeyHex())
	}
	if got := k.SignBase64(f["signPayload"]); got != f["signature"] {
		t.Fatalf("signature\n got %s\nwant %s", got, f["signature"])
	}
	if k.PrivateKeyHex() != f["seed"] {
		t.Fatal("seed round trip")
	}
}

func TestSwiftRecordIsPortable(t *testing.T) {
	data, _ := os.ReadFile(filepath.Join("testdata", "device-record-swift.json"))
	var r Record
	if err := json.Unmarshal(data, &r); err != nil {
		t.Fatal(err)
	}
	want := time.Unix(978307200+815223600, 5e8).UTC()
	if r.DeviceTokenExpiresAt == nil || !r.DeviceTokenExpiresAt.Equal(want) {
		t.Fatalf("expiry %v want %v", r.DeviceTokenExpiresAt, want)
	}
	if r.APIBase != "https://bromure.io/api" || r.Capability != "agent-host" || *r.OrgKind != "individual" || r.RecordsSessionTelemetry() {
		t.Fatalf("record %+v", r)
	}
	// Written back, Swift's decoder reads the same Date (a number).
	out, _ := json.Marshal(r)
	var m map[string]any
	_ = json.Unmarshal(out, &m)
	if v, ok := m["deviceTokenExpiresAt"].(float64); !ok || v != 815223600.5 {
		t.Fatalf("expiry encodes as %v", m["deviceTokenExpiresAt"])
	}
	// nil optionals are omitted, like Swift's encodeIfPresent.
	r.OrgSlug, r.OrgKind, r.DeviceTokenExpiresAt = nil, nil, nil
	out, _ = json.Marshal(r)
	if strings.Contains(string(out), "orgSlug") || strings.Contains(string(out), "deviceTokenExpiresAt") {
		t.Fatalf("nil optionals encoded: %s", out)
	}
}

func TestParseLink(t *testing.T) {
	cases := []struct {
		in, code, api string
		ok            bool
	}{
		{"bromure-agent-host://enroll?code=AbC-123_xyz&state=S1", "AbC-123_xyz", DefaultAPIBase, true},
		{"  bromure://enroll?v=1&code=c0de&api=http%3A%2F%2F127.0.0.1%3A3847\n", "c0de", "http://127.0.0.1:3847", true},
		{"https://bromure.io/app/enroll?code=a+b", "a+b", DefaultAPIBase, true}, // '+' stays literal (URLComponents)
		{"https://bromure.io/other?code=x", "", "", false},
		{"bromure-agent-host://enroll?state=S1", "", "", false},
		{"ABCDEFGHijklmnop", "ABCDEFGHijklmnop", DefaultAPIBase, true},
		{"short-code", "", "", false},
		{"has space in it but long enough", "", "", false},
		{"ABCDEFGHijklmnop!", "", "", false},
		{"", "", "", false},
	}
	for _, c := range cases {
		l, ok := ParseLink(c.in)
		if ok != c.ok || l.Code != c.code || (ok && l.APIBase != c.api) {
			t.Errorf("%q -> %+v %v", c.in, l, ok)
		}
	}
	if v, ok := QueryValue("bromure-agent-host://enroll?code=x&state=AB-12", "state"); !ok || v != "AB-12" {
		t.Fatalf("state %q %v", v, ok)
	}
	if _, ok := QueryValue("ABCDEFGHijklmnop", "state"); ok {
		t.Fatal("bare code has a state")
	}
}

// A fake control plane runs the two-phase enroll and checks the signature
// over its signPayload with the posted public key.
func TestEnroll(t *testing.T) {
	dir := t.TempDir()
	Path = func() string { return filepath.Join(dir, "device-record.json") }
	defer func(old func() string) { Path = old }(paths.DeviceRecord)
	var pub ed25519.PublicKey
	const payload = "bromure-p2p-enroll:v1:ch-1:Q2hhbGxlbmdl"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/devices/enroll" || r.Method != "POST" || r.Header.Get("Authorization") != "" {
			http.Error(w, `{"error":"bad"}`, 400)
			return
		}
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		if code, ok := body["code"]; ok {
			if code != "THE-CODE" || body["deviceName"] != "Your Machine" || body["capability"] != nil {
				http.Error(w, `{"error":"bad_code"}`, 400)
				return
			}
			b, _ := hex.DecodeString(body["devicePubkey"].(string))
			pub = b
			json.NewEncoder(w).Encode(map[string]any{"challengeId": "ch-1", "challenge": "Q2hhbGxlbmdl",
				"signPayload": payload, "capability": "agent-host", "expiresInSeconds": 120})
			return
		}
		sig, _ := base64.StdEncoding.DecodeString(body["signature"].(string))
		if body["challengeId"] != "ch-1" || !ed25519.Verify(pub, []byte(payload), sig) {
			http.Error(w, `{"error":"bad_signature"}`, 401)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"deviceId": "dev-9", "deviceToken": "tok-9",
			"deviceTokenExpiresAt": "2027-01-02T03:04:05.678Z", "capability": "agent-host",
			"orgSlug": nil, "orgKind": "individual", "userId": "u-1"})
	}))
	defer srv.Close()
	name := "Your Machine"
	rec, err := Enroll(context.Background(), Link{"THE-CODE", srv.URL}, &name, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if rec.DeviceID != "dev-9" || rec.APIBase != srv.URL || rec.DeviceTokenExpiresAt == nil {
		t.Fatalf("record %+v", rec)
	}
	id, ok := Current()
	if !ok || id.Bearer != "tok-9" || id.InstallID != "dev-9" || id.RecordsSessionTelemetry() {
		t.Fatalf("identity %+v %v", id, ok)
	}
	k, _ := SigningKeyFromHex(id.Record.PrivateKeyHex)
	if k.PublicKeyHex() != hex.EncodeToString(pub) {
		t.Fatal("stored key isn't the enrolled one")
	}
	Erase()
	if _, res := Load(); res != NotEnrolled {
		t.Fatal("erase")
	}
	os.WriteFile(Path(), []byte("{not json"), 0o600)
	if _, res := Load(); res != Unavailable {
		t.Fatal("corrupt record must be Unavailable, not NotEnrolled")
	}
}
