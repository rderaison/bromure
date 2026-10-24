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

// DefaultFeed is where release-upload publishes the Windows feed.
const DefaultFeed = "https://bromure.io/downloads/bromure-sidecar-windows/latest.json"

// feedForOS is the feed for the running platform. The product name carries
// the OS, because the assets are not interchangeable: a Windows release is an
// Inno setup .exe and a Linux one is a tarball. Without this split a Linux
// daemon reads the WINDOWS feed, compares against Windows versions and offers
// to download a setup.exe.
//
// The Linux and macOS paths follow the Windows naming, but nothing publishes
// them yet -- that is an infra choice, flagged for the user, exactly as the
// Windows path was.
func feedForOS() string {
	switch runtime.GOOS {
	case "windows":
		return DefaultFeed
	case "darwin":
		return "https://bromure.io/downloads/bromure-sidecar-macos/latest.json"
	default:
		return "https://bromure.io/downloads/bromure-sidecar-linux/latest.json"
	}
}

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
	url := settings.String(FeedKey, feedForOS())
	if url == "" {
		return nil, nil
	}
	req, _ := http.NewRequestWithContext(ctx, "GET", url, nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == 404 {
		// Nothing is published for this platform. Distinguished from a real
		// failure because it is the normal state on Linux and macOS until
		// the release job publishes their feeds, and "update feed: HTTP 404"
		// reads to a user as something being broken.
		return nil, ErrNoFeed
	}
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
// ErrNoFeed: no release feed is published for this platform yet.
var ErrNoFeed = errors.New("no release feed is published for this platform yet")

// ErrInstallUnsupported: this platform has no in-place updater.
//
// The Windows path downloads an Inno setup .exe and runs it silently. On
// Linux that asset does not exist and could not be executed, so Install
// REFUSES rather than downloading something it cannot run -- a daemon that
// fetches and launches the wrong artifact is worse than one that says it
// cannot. Linux updates go through the release tarball and
// installer/linux/install.sh, which also restarts the user service; the
// binary of a running daemon cannot simply be overwritten in place.
var ErrInstallUnsupported = errors.New("in-place update is Windows-only: " +
	"on Linux, unpack the release tarball and run installer/linux/install.sh")

func Install(ctx context.Context, r *Release) error {
	if runtime.GOOS != "windows" {
		return ErrInstallUnsupported
	}
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
