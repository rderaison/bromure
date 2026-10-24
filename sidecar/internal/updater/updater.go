// Package updater is v1 of the Windows updates: a JSON feed, a download
// checked against its SHA-256, and the per-user installer run silently.
// The pane host is never replaced while it has windows: the daemon swaps it
// at its next idle moment (cmd/bromure-sidecar upgradePaneHostWhenIdle).
//
// Feed (product bromure-sidecar-windows; its location is an infra choice,
// settings key "updateFeed" overrides the default):
//
//	{"version": "1.2.3", "url": "https://…/BromureSidecar-1.2.3-x64.exe",
//	 "sha256": "…", "arm64": {"url": "…", "sha256": "…"}}
package updater

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/settings"
)

// DefaultFeed is where release-upload publishes the feed.
const DefaultFeed = "https://bromure.io/downloads/bromure-sidecar-windows/latest.json"

// FeedKey overrides the feed URL (an empty string disables updates).
const FeedKey = "updateFeed"

// Release is one feed entry for this architecture.
type Release struct {
	Version string `json:"version"`
	URL     string `json:"url"`
	SHA256  string `json:"sha256"`
}

type feed struct {
	Release
	ARM64 *Release `json:"arm64,omitempty"`
}

// Check reads the feed; nil when nothing newer than current.
func Check(ctx context.Context, current string) (*Release, error) {
	url := settings.String(FeedKey, DefaultFeed)
	if url == "" {
		return nil, nil
	}
	req, _ := http.NewRequestWithContext(ctx, "GET", url, nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("update feed: HTTP %d", resp.StatusCode)
	}
	var f feed
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&f); err != nil {
		return nil, err
	}
	r := f.Release
	if runtime.GOARCH == "arm64" && f.ARM64 != nil {
		r.URL, r.SHA256 = f.ARM64.URL, f.ARM64.SHA256
	}
	if r.URL == "" || !strings.HasPrefix(r.URL, "https://") || len(r.SHA256) != 64 {
		return nil, errors.New("update feed: incomplete entry")
	}
	if !Newer(r.Version, current) {
		return nil, nil
	}
	return &r, nil
}

// Newer compares dotted versions ("1.10.0" > "1.9.2"); a dev build never
// updates.
func Newer(candidate, current string) bool {
	if current == "dev" || current == "" {
		return false
	}
	a, b := parts(candidate), parts(current)
	for i := 0; i < len(a) || i < len(b); i++ {
		var x, y int
		if i < len(a) {
			x = a[i]
		}
		if i < len(b) {
			y = b[i]
		}
		if x != y {
			return x > y
		}
	}
	return false
}

func parts(v string) []int {
	v = strings.TrimPrefix(v, "v")
	if i := strings.IndexAny(v, "-+"); i >= 0 {
		v = v[:i]
	}
	out := []int{}
	for _, p := range strings.Split(v, ".") {
		n, _ := strconv.Atoi(p)
		out = append(out, n)
	}
	return out
}

// Install downloads the release, checks its SHA-256 and runs the
// installer silently (it stops the tray and daemon and starts them again).
func Install(ctx context.Context, r *Release) error {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Minute)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, "GET", r.URL, nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("download: HTTP %d", resp.StatusCode)
	}
	dir, err := os.MkdirTemp("", "bromure-sidecar-update-")
	if err != nil {
		return err
	}
	dst := filepath.Join(dir, "BromureSidecar-setup.exe")
	f, err := os.Create(dst)
	if err != nil {
		return err
	}
	h := sha256.New()
	_, err = io.Copy(io.MultiWriter(f, h), io.LimitReader(resp.Body, 512<<20))
	f.Close()
	if err != nil {
		return err
	}
	if got := hex.EncodeToString(h.Sum(nil)); !strings.EqualFold(got, r.SHA256) {
		os.RemoveAll(dir)
		return fmt.Errorf("download: SHA-256 mismatch (%s)", got)
	}
	cmd := exec.Command(dst, "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART")
	return cmd.Start()
}
