package controlplane

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestEndpointNormalize(t *testing.T) {
	cases := map[string]string{
		"https://bromure.io":          "https://bromure.io/api",
		" https://bromure.io/ ":       "https://bromure.io/api",
		"https://bromure.io/api":      "https://bromure.io/api",
		"http://127.0.0.1:3847":       "http://127.0.0.1:3847",
		"http://localhost:3847/":      "http://localhost:3847",
		"https://dev.local":           "https://dev.local",
		"https://staging.example/v2/": "https://staging.example/v2",
	}
	for in, want := range cases {
		ep, err := NewEndpoint(in)
		if err != nil || ep.String() != want {
			t.Errorf("%q -> %q %v", in, ep.String(), err)
		}
	}
	for _, bad := range []string{"bromure.io", "", "://x"} {
		if _, err := NewEndpoint(bad); err == nil {
			t.Errorf("%q accepted", bad)
		}
	}
	ep, _ := NewEndpoint("https://bromure.io")
	if ep.URL("/v1/devices") != "https://bromure.io/api/v1/devices" || ep.DeviceChannelURL() != "wss://bromure.io/api/v1/device-channel" {
		t.Fatalf("%s %s", ep.URL("/v1/devices"), ep.DeviceChannelURL())
	}
	ep, _ = NewEndpoint("http://127.0.0.1:3847")
	if ep.DeviceChannelURL() != "ws://127.0.0.1:3847/v1/device-channel" {
		t.Fatal(ep.DeviceChannelURL())
	}
}

func TestRoutes(t *testing.T) {
	type seen struct{ method, path, auth, body string }
	var got []seen
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var raw json.RawMessage
		_ = json.NewDecoder(r.Body).Decode(&raw)
		got = append(got, seen{r.Method, r.URL.Path, r.Header.Get("Authorization"), string(raw)})
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/v1/devices":
			w.Write([]byte(`{"devices":[{"id":"d1","name":null,"capability":null,"revoked":false,"online":true,"lastSeenAt":null,"self":true,"sshUsername":"you"}]}`))
		case "/v1/connections":
			w.Write([]byte(`{"connection":{"id":"c1","expiresAt":"x","self":{"deviceId":"a","signalId":"s","role":"client"},"peer":{"deviceId":"b","signalId":"t","role":"server"}}}`))
		case "/v1/devices/server-mode":
			w.Write([]byte(`{"ok":true,"server":true}`))
		case "/v1/connections/c1/turn-credentials":
			w.Write([]byte(`{"turn":{"urls":["turns:relay.example:5349?transport=tcp"],"username":"1:c1","credential":"p","ttlSeconds":3600,"expiresAt":"x","region":"eu"}}`))
		case "/v1/connections/c2/turn-credentials":
			w.WriteHeader(503)
			w.Write([]byte(`{"error":"turn_unavailable"}`))
		case "/v1/connections/c1/complete":
			w.Write([]byte(`{"ok":true,"recorded":true}`))
		case "/v1/devices/ssh-keys":
			w.Write([]byte(`{"keys":[{"id":"d2","name":"Mac","sshPublicKey":"ssh-ed25519 AAAA x","capability":"agent-host"},{"id":"d3","name":null,"sshPublicKey":"ssh-ed25519 BBBB","capability":null}]}`))
		case "/v1/devices/ssh-key", "/v1/devices/self-revoke":
			w.Write([]byte(`{"ok":true}`))
		default:
			w.WriteHeader(404)
			w.Write([]byte(`{"error":"not_found"}`))
		}
	}))
	defer srv.Close()
	ep, _ := NewEndpoint(srv.URL)
	c := New(ep)
	ctx := context.Background()
	devs, err := c.ListDevices(ctx, "tok")
	if err != nil || len(devs) != 1 || !devs[0].IsSelf || devs[0].DisplayName() != "d1" || *devs[0].SSHUsername != "you" {
		t.Fatalf("devices %+v %v", devs, err)
	}
	g, err := c.RequestConnection(ctx, "tok", "b")
	if err != nil || g.ID != "c1" || g.Self.Role != "client" || g.Peer.DeviceID != "b" {
		t.Fatalf("grant %+v %v", g, err)
	}
	if on, err := c.SetServerMode(ctx, "tok", true); !on || err != nil {
		t.Fatal("server mode")
	}
	tc, err := c.TurnCredentials(ctx, "tok", "c1")
	if err != nil || tc.URLs[0] != "turns:relay.example:5349?transport=tcp" || tc.Username != "1:c1" {
		t.Fatalf("creds %+v %v", tc, err)
	}
	if _, err := c.TurnCredentials(ctx, "tok", "c2"); !errors.Is(err, ErrTurnUnavailable) {
		t.Fatalf("503: %v", err)
	}
	if rec, err := c.Complete(ctx, "tok", "c1", Connected("relay", 1234)); !rec || err != nil {
		t.Fatal("complete")
	}
	keys, err := c.ListSSHKeys(ctx, "tok")
	if err != nil || keys[0].AuthorizedKeysComment() != "bromure-account:machine:d2" || keys[1].AuthorizedKeysComment() != "bromure-account:d3" {
		t.Fatalf("keys %+v %v", keys, err)
	}
	if err := c.UploadSSHKey(ctx, "tok", "ssh-ed25519 AAAA bromure-agent-host", "you"); err != nil {
		t.Fatal(err)
	}
	if err := c.SelfRevoke(ctx, "tok"); err != nil {
		t.Fatal(err)
	}
	if err := c.RemoveSSHKey(ctx, "tok"); err != nil {
		t.Fatal(err)
	}
	var he *HTTPError
	_, err = c.EnrollBegin(ctx, "code", "ab", nil, nil)
	if !errors.As(err, &he) || he.Status != 404 || he.Code != "not_found" {
		t.Fatalf("404: %v", err)
	}
	// Bodies use the Swift's field names; the bearer rides every call but enroll.
	want := map[string]string{
		"/v1/connections":                     `{"deviceId":"b"}`,
		"/v1/devices/server-mode":             `{"enabled":true}`,
		"/v1/connections/c1/turn-credentials": `{}`,
		"/v1/connections/c1/complete":         `{"outcome":"connected","pathKind":"relay","timeToConnectedMs":1234}`,
		"/v1/devices/self-revoke":             `{}`,
		"/v1/devices/enroll":                  `{"code":"code","devicePubkey":"ab"}`,
		"/v1/devices/ssh-key":                 `{"sshPublicKey":"ssh-ed25519 AAAA bromure-agent-host","sshUsername":"you"}`,
	}
	for _, s := range got {
		if w, ok := want[s.path]; ok && s.method == "POST" && s.body != w {
			t.Errorf("%s body %s want %s", s.path, s.body, w)
		}
		if s.path == "/v1/devices/enroll" {
			if s.auth != "" {
				t.Error("enroll carried a bearer")
			}
		} else if s.auth != "Bearer tok" {
			t.Errorf("%s auth %q", s.path, s.auth)
		}
	}
	if b, _ := json.Marshal(Failed("signaling")); string(b) != `{"outcome":"failed","failureStage":"signaling"}` {
		t.Fatalf("failed report %s", b)
	}
}
