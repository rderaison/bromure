// Package settings is settings.json in the data dir: what the macOS
// Sidecar keeps in UserDefaults (sshPort, attach.target, machineName,
// p2p.published, approvals.<tool>, debugExec, …) as one JSON object.
//
// The daemon is the writer; other processes (the tray, helpers) read, and
// change settings through the control socket. A read picks up a file
// another process rewrote (mtime check).
package settings

import (
	"encoding/json"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/paths"
)

// Well-known keys.
const (
	SSHPort        = "sshPort"       // int, default 2223 (2224 is suggested for the Go Sidecar on a Mac)
	AttachTarget   = "attach.target" // object, machinelink.Target
	MachineName    = "machineName"   // string
	P2PPublished   = "p2p.published" // bool
	DebugExec      = "debugExec"     // bool
	GitBashPath    = "CLAUDE_CODE_GIT_BASH_PATH"
	PendingEnroll  = "pending-enroll-state"
	StartAtLogin   = "startAtLogin" // bool
	ApprovalPrefix = "approvals."   // + tool: ask | auto | full
)

var (
	mu     sync.Mutex
	values map[string]json.RawMessage
	mtime  time.Time
)

func loadLocked() {
	p := paths.SettingsFile()
	st, err := os.Stat(p)
	if err != nil {
		if values == nil {
			values = map[string]json.RawMessage{}
		}
		return
	}
	if values != nil && st.ModTime().Equal(mtime) {
		return
	}
	data, err := os.ReadFile(p)
	m := map[string]json.RawMessage{}
	if err == nil {
		_ = json.Unmarshal(data, &m)
	}
	values = m
	mtime = st.ModTime()
}

func saveLocked() error {
	data, err := json.MarshalIndent(values, "", "  ")
	if err != nil {
		return err
	}
	p := paths.SettingsFile()
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, p); err != nil {
		return err
	}
	if st, err := os.Stat(p); err == nil {
		mtime = st.ModTime()
	}
	return nil
}

// Get decodes key into out; false when unset or not decodable.
func Get(key string, out any) bool {
	mu.Lock()
	defer mu.Unlock()
	loadLocked()
	raw, ok := values[key]
	if !ok {
		return false
	}
	return json.Unmarshal(raw, out) == nil
}

// Set stores v under key (nil removes it).
func Set(key string, v any) error {
	mu.Lock()
	defer mu.Unlock()
	loadLocked()
	if v == nil {
		delete(values, key)
	} else {
		raw, err := json.Marshal(v)
		if err != nil {
			return err
		}
		values[key] = raw
	}
	return saveLocked()
}

// Remove deletes key.
func Remove(key string) error { return Set(key, nil) }

// All is every stored setting, as raw JSON values. A copy: the caller must
// not be able to mutate the live map, and callers outside this package have
// no lock to hold.
//
// Added for the Linux CLI's `settings` command, which has no tray to read
// them from. Secrets do not live here (keys are files in the data dir), but
// `pending-enroll-state` is a one-shot handoff nonce, so the caller decides
// what to print.
func All() map[string]json.RawMessage {
	mu.Lock()
	defer mu.Unlock()
	loadLocked()
	out := make(map[string]json.RawMessage, len(values))
	for k, v := range values {
		out[k] = v
	}
	return out
}

// Has reports whether key is set.
func Has(key string) bool {
	mu.Lock()
	defer mu.Unlock()
	loadLocked()
	_, ok := values[key]
	return ok
}

func String(key, def string) string {
	var s string
	if Get(key, &s) {
		return s
	}
	return def
}

func Bool(key string, def bool) bool {
	var b bool
	if Get(key, &b) {
		return b
	}
	return def
}

func Int(key string, def int) int {
	var n int
	if Get(key, &n) {
		return n
	}
	// Tolerate a hand-edited "2224".
	var s string
	if Get(key, &s) {
		if v, err := strconv.Atoi(s); err == nil {
			return v
		}
	}
	return def
}

// SSHPortValue is the embedded SSH server's port (127.0.0.1 only).
func SSHPortValue() int {
	if v := os.Getenv("BROMURE_SIDECAR_SSH_PORT"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return Int(SSHPort, 2223)
}

// ResetForTest forgets the cached file.
func ResetForTest() {
	mu.Lock()
	values = nil
	mtime = time.Time{}
	mu.Unlock()
}
