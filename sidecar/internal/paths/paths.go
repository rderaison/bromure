// Package paths is everything Bromure Sidecar keeps on disk.
//
//	Windows: %LOCALAPPDATA%\BromureSidecar\
//	macOS:   ~/Library/Application Support/BromureSidecar-go/  (never the Swift Sidecar's)
//	Linux:   ~/.local/share/BromureSidecar/  ($XDG_DATA_HOME honoured)
//
// BROMURE_SIDECAR_DATA overrides the whole directory (tests, a second
// instance on one machine).
package paths

import (
	"os"
	"path/filepath"
	"runtime"
	"sync"
)

var (
	once    sync.Once
	dataDir string
)

// DataDir is the root of everything the Sidecar keeps.
func DataDir() string {
	once.Do(func() {
		if d := os.Getenv("BROMURE_SIDECAR_DATA"); d != "" {
			dataDir = d
			return
		}
		home, _ := os.UserHomeDir()
		switch runtime.GOOS {
		case "windows":
			base := os.Getenv("LOCALAPPDATA")
			if base == "" {
				base = filepath.Join(home, "AppData", "Local")
			}
			dataDir = filepath.Join(base, "BromureSidecar")
		case "darwin":
			dataDir = filepath.Join(home, "Library", "Application Support", "BromureSidecar-go")
		default:
			base := os.Getenv("XDG_DATA_HOME")
			if base == "" {
				base = filepath.Join(home, ".local", "share")
			}
			dataDir = filepath.Join(base, "BromureSidecar")
		}
	})
	return dataDir
}

// SetDataDirForTest points every path below at dir.
func SetDataDirForTest(dir string) {
	once.Do(func() {})
	dataDir = dir
}

func in(parts ...string) string { return filepath.Join(append([]string{DataDir()}, parts...)...) }

// The control API (HTTP/1.1 over AF_UNIX); fat clients reach it over SSH.
func ControlSocket() string { return in("control.sock") }

// The pane host's socket (JSON + binary frames).
func PanesSocket() string { return in("panes.sock") }

// Where the agents' delegation MCP streams meet a parked SSH channel.
func DelegationSocket() string { return in("delegation.sock") }

func RemoteDir() string       { return in("remote") }
func HostKey() string         { return in("remote", "hostkey_ed25519") }
func HostKeyPub() string      { return in("remote", "hostkey_ed25519.pub") }
func AuthorizedKeys() string  { return in("remote", "authorized_keys") }
func ClientKey() string       { return in("client_ed25519") }
func KnownHosts() string      { return in("known_hosts") }
func DeviceRecord() string    { return in("device-record.json") }
func SessionsFile() string    { return in("sessions.json") }
func SettingsFile() string    { return in("settings.json") }
func HostIDFile() string      { return in("host-id") }
func ClaudeSettings() string  { return in("claude-settings.json") }
func ClaudeMCPConfig() string { return in("claude-mcp.json") }
func LogsDir() string         { return in("logs") }
func LogFile() string         { return in("logs", "bromure-sidecar.log") }

// BinDir goes first on the PATH of everything a client runs here: the
// `tmux` and `ps` shims.
func BinDir() string { return in("bin") }

// Home is the user's real home (%USERPROFILE% on Windows).
func Home() string {
	if runtime.GOOS == "windows" {
		if p := os.Getenv("USERPROFILE"); p != "" {
			return p
		}
	}
	h, _ := os.UserHomeDir()
	return h
}

// BromureHome is ~/.bromure, the folder Bromure AC reads directly
// (transcript pins, pq dumps, worktrees, inbox, drops).
func BromureHome() string { return filepath.Join(Home(), ".bromure") }

// DropsDir is where files dropped on a client's composer land.
func DropsDir() string { return filepath.Join(BromureHome(), "drops") }

// Executable is this binary, symlinks resolved.
func Executable() string {
	exe, err := os.Executable()
	if err != nil {
		return os.Args[0]
	}
	if r, err := filepath.EvalSymlinks(exe); err == nil {
		return r
	}
	return exe
}

// ExeName is the console binary's file name on this OS.
func ExeName(base string) string {
	if runtime.GOOS == "windows" {
		return base + ".exe"
	}
	return base
}

// Ensure makes the data dir and its sub-folders, owner-only.
func Ensure() error {
	for _, d := range []string{DataDir(), RemoteDir(), LogsDir(), BinDir()} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			return err
		}
	}
	return Protect(DataDir())
}
