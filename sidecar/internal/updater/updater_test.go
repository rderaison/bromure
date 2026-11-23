package updater

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/rderaison/bromure/sidecar/internal/paths"
	"github.com/rderaison/bromure/sidecar/internal/settings"
)

func TestNewer(t *testing.T) {
	for _, c := range []struct {
		a, b string
		want bool
	}{
		{"1.10.0", "1.9.2", true}, {"1.2.3", "1.2.3", false}, {"1.2.3", "1.2.4", false},
		{"v2.0", "1.99.99", true}, {"1.2.4-beta", "1.2.3", true}, {"9.9.9", "dev", false},
	} {
		if got := Newer(c.a, c.b); got != c.want {
			t.Errorf("Newer(%q, %q) = %v", c.a, c.b, got)
		}
	}
}

func TestCheckAndDownload(t *testing.T) {
	paths.SetDataDirForTest(t.TempDir())
	settings.ResetForTest()
	payload := []byte("pretend installer")
	sum := sha256.Sum256(payload)
	var srv *httptest.Server
	srv = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/latest.json":
			json.NewEncoder(w).Encode(map[string]any{"version": "1.2.0", "url": srv.URL + "/setup.exe", "sha256": hex.EncodeToString(sum[:]),
				"arm64": map[string]any{"url": srv.URL + "/setup.exe", "sha256": hex.EncodeToString(sum[:])}})
		case "/setup.exe":
			w.Write(payload)
		}
	}))
	defer srv.Close()
	Client = srv.Client()
	defer func() { Client = http.DefaultClient }()
	settings.Set(FeedKey, srv.URL+"/latest.json")

	if r, err := Check(context.Background(), "1.2.0"); err != nil || r != nil {
		t.Fatalf("same version: %v %v", r, err)
	}
	r, err := Check(context.Background(), "1.1.9")
	if err != nil || r == nil || r.Version != "1.2.0" {
		t.Fatalf("newer: %+v %v", r, err)
	}
	p, err := Download(context.Background(), r)
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(filepath.Dir(p))
	if data, _ := os.ReadFile(p); string(data) != string(payload) {
		t.Fatal("payload")
	}
	bad := *r
	bad.SHA256 = hex.EncodeToString(make([]byte, 32))
	if _, err := Download(context.Background(), &bad); err == nil {
		t.Fatal("a SHA-256 mismatch must be refused")
	}
	settings.Set(FeedKey, "")
	if r, err := Check(context.Background(), "0.0.1"); r != nil || err != nil {
		t.Fatal("an empty feed disables updates")
	}
}
