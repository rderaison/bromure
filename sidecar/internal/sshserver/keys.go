package sshserver

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"os"
	"strconv"
	"strings"
	"sync"

	"golang.org/x/crypto/ssh"

	"github.com/rderaison/bromure/sidecar/internal/paths"
)

// Comment markers on authorized_keys lines.
const (
	// AccountKeyMarker prefixes every key the account sync manages
	// (P2PAccount.accountKeyMarker).
	AccountKeyMarker = "bromure-account:"
	// MachineKeyMarker prefixes the account keys of Bromure Sidecars
	// (bromure.io capability agent-host): they may only attach that
	// machine (machine-link / machine-detach). The rest is the device id.
	MachineKeyMarker = "bromure-account:machine:"
	// hostKeyComment is the host key's .pub comment (as the Swift writes it).
	hostKeyComment = "bromure-ac-remote"
)

// ErrBadKey is AddAuthorizedKey's refusal.
var ErrBadKey = errors.New("Not a valid public key: couldn't parse it (supported: ed25519, ecdsa)")

var fileMu sync.Mutex // authorized_keys and the host key files

// MARK: host key

func ensureLayout() error {
	if err := os.MkdirAll(paths.RemoteDir(), 0o700); err != nil {
		return err
	}
	_ = paths.Protect(paths.RemoteDir())
	if _, err := os.Stat(paths.AuthorizedKeys()); os.IsNotExist(err) {
		if err := os.WriteFile(paths.AuthorizedKeys(), nil, 0o600); err != nil {
			return err
		}
		_ = paths.ProtectFile(paths.AuthorizedKeys())
	}
	return nil
}

func readHostSeed() (ed25519.PrivateKey, bool) {
	d, err := os.ReadFile(paths.HostKey())
	if err != nil || len(d) != ed25519.SeedSize {
		return nil, false
	}
	return ed25519.NewKeyFromSeed(d), true
}

// loadOrCreateHostKey loads the raw 32-byte seed (generating it when
// missing or malformed) and always rewrites the .pub line.
func loadOrCreateHostKey() (ssh.Signer, error) {
	fileMu.Lock()
	defer fileMu.Unlock()
	if err := ensureLayout(); err != nil {
		return nil, err
	}
	key, ok := readHostSeed()
	if !ok {
		seed := make([]byte, ed25519.SeedSize)
		if _, err := rand.Read(seed); err != nil {
			return nil, err
		}
		if err := writeAtomic(paths.HostKey(), seed); err != nil {
			return nil, err
		}
		_ = paths.ProtectFile(paths.HostKey())
		key = ed25519.NewKeyFromSeed(seed)
	}
	signer, err := ssh.NewSignerFromKey(key)
	if err != nil {
		return nil, err
	}
	_ = writeAtomic(paths.HostKeyPub(), []byte(publicLine(signer.PublicKey(), hostKeyComment)))
	return signer, nil
}

func publicLine(k ssh.PublicKey, comment string) string {
	return k.Type() + " " + base64.StdEncoding.EncodeToString(k.Marshal()) + " " + comment
}

func fingerprintBlob(blob []byte) string {
	sum := sha256.Sum256(blob)
	return "SHA256:" + base64.RawStdEncoding.EncodeToString(sum[:])
}

// HostKeyFingerprint is the host key's fingerprint in ssh-keygen -l's
// format, "256 SHA256:… bromure-ac-remote (ED25519)" ("" with no key).
func HostKeyFingerprint() string {
	key, ok := readHostSeed()
	if !ok {
		return ""
	}
	pub, err := ssh.NewPublicKey(key.Public())
	if err != nil {
		return ""
	}
	return "256 " + fingerprintBlob(pub.Marshal()) + " " + hostKeyComment + " (ED25519)"
}

// HostPublicKeyLine is the host key's OpenSSH line ("" with no key).
func HostPublicKeyLine() string {
	key, ok := readHostSeed()
	if !ok {
		return ""
	}
	pub, err := ssh.NewPublicKey(key.Public())
	if err != nil {
		return ""
	}
	return publicLine(pub, hostKeyComment)
}

// MARK: authorized keys

// AuthorizedKey is one authorized_keys entry.
type AuthorizedKey struct {
	Line        string `json:"line"`
	Type        string `json:"type"`
	Comment     string `json:"comment"`
	Fingerprint string `json:"fingerprint"`
}

func splitSpaces(s string, max int) []string {
	// Swift's split(separator: " ", maxSplits:) with empty runs omitted.
	var out []string
	for len(out) < max-1 {
		s = strings.TrimLeft(s, " ")
		if s == "" {
			return out
		}
		i := strings.IndexByte(s, ' ')
		if i < 0 {
			return append(out, s)
		}
		out = append(out, s[:i])
		s = s[i+1:]
	}
	s = strings.TrimLeft(s, " ")
	if s != "" {
		out = append(out, s)
	}
	return out
}

func fileLines(body string) []string {
	return strings.FieldsFunc(body, func(r rune) bool { return r == '\n' || r == '\r' })
}

func listLocked() []AuthorizedKey {
	body, err := os.ReadFile(paths.AuthorizedKeys())
	if err != nil {
		return nil
	}
	var out []AuthorizedKey
	for _, raw := range fileLines(string(body)) {
		line := strings.Trim(raw, " \t")
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := splitSpaces(line, 3)
		if len(parts) < 2 {
			continue
		}
		comment := ""
		if len(parts) >= 3 {
			comment = parts[2]
		}
		fp := "?"
		if f := fingerprintOfLine(line); f != "" {
			fp = f
		}
		out = append(out, AuthorizedKey{Line: line, Type: parts[0], Comment: comment, Fingerprint: fp})
	}
	return out
}

// ListAuthorizedKeys is authorized_keys, comments and blank lines left out.
func ListAuthorizedKeys() []AuthorizedKey {
	fileMu.Lock()
	defer fileMu.Unlock()
	return listLocked()
}

func fingerprintOfLine(line string) string {
	f := splitSpaces(line, 3)
	if len(f) < 2 {
		return ""
	}
	blob, err := base64.StdEncoding.DecodeString(f[1])
	if err != nil {
		return ""
	}
	return fingerprintBlob(blob)
}

var allowedTypes = map[string]bool{
	ssh.KeyAlgoED25519:  true,
	ssh.KeyAlgoECDSA256: true,
	ssh.KeyAlgoECDSA384: true,
	ssh.KeyAlgoECDSA521: true,
}

// parseKeyLine parses "<algo> <b64> [comment]" the way the server will
// (the Swift's NIOSSHPublicKey(openSSHPublicKey:): ed25519 and ecdsa only).
func parseKeyLine(line string) (ssh.PublicKey, error) {
	f := splitSpaces(strings.TrimSpace(line), 3)
	if len(f) < 2 || !allowedTypes[f[0]] {
		return nil, ErrBadKey
	}
	blob, err := base64.StdEncoding.DecodeString(f[1])
	if err != nil {
		return nil, ErrBadKey
	}
	k, err := ssh.ParsePublicKey(blob)
	if err != nil || k.Type() != f[0] {
		return nil, ErrBadKey
	}
	return k, nil
}

func keyBlob(line string) string {
	f := splitSpaces(line, 3)
	if len(f) > 2 {
		f = f[:2]
	}
	return strings.Join(f, " ")
}

func writeKeysLocked(lines []string) error {
	body := strings.Join(lines, "\n")
	if body != "" {
		body += "\n"
	}
	if err := writeAtomic(paths.AuthorizedKeys(), []byte(body)); err != nil {
		return err
	}
	_ = paths.ProtectFile(paths.AuthorizedKeys())
	return nil
}

// AddAuthorizedKey adds an OpenSSH public key line, replacing any line with
// the same key (type and blob), and applies it to a running server.
func AddAuthorizedKey(raw string) error {
	key := strings.TrimSpace(raw)
	if _, err := parseKeyLine(key); err != nil {
		return err
	}
	fileMu.Lock()
	if err := ensureLayout(); err != nil {
		fileMu.Unlock()
		return err
	}
	var lines []string
	if body, err := os.ReadFile(paths.AuthorizedKeys()); err == nil {
		lines = fileLines(string(body))
	}
	blob := keyBlob(key)
	kept := lines[:0]
	for _, l := range lines {
		if keyBlob(l) != blob {
			kept = append(kept, l)
		}
	}
	kept = append(kept, key)
	err := writeKeysLocked(kept)
	fileMu.Unlock()
	if err != nil {
		return err
	}
	reloadRunning()
	return nil
}

// RemoveAuthorizedKey removes by selector, as the Swift reads it: a
// 1-based index into ListAuthorizedKeys, else every key whose fingerprint
// equals or contains it.
func RemoveAuthorizedKey(selector string) error {
	fileMu.Lock()
	keys := listLocked()
	sel := strings.Trim(selector, " \t")
	if idx, err := strconv.Atoi(sel); err == nil && idx >= 1 && idx <= len(keys) {
		keys = append(keys[:idx-1], keys[idx:]...)
	} else if sel != "" {
		kept := keys[:0]
		for _, k := range keys {
			if k.Fingerprint == sel || strings.Contains(k.Fingerprint, sel) {
				continue
			}
			kept = append(kept, k)
		}
		keys = kept
	}
	lines := make([]string, 0, len(keys))
	for _, k := range keys {
		lines = append(lines, k.Line)
	}
	err := writeKeysLocked(lines)
	fileMu.Unlock()
	if err != nil {
		return err
	}
	reloadRunning()
	return nil
}

// SetManagedKeys reconciles the account-managed keys (comment starting with
// marker) to exactly lines, leaving every manually added key untouched. One
// write and one hot reload, and only when the managed set changed (a key
// sync never disturbs live sessions).
func SetManagedKeys(marker string, lines []string) {
	fileMu.Lock()
	current := listLocked()
	managedNow := map[string]bool{}
	var manual []AuthorizedKey
	for _, k := range current {
		if strings.HasPrefix(k.Comment, marker) {
			managedNow[k.Line] = true
		} else {
			manual = append(manual, k)
		}
	}
	// A desired key that duplicates a manual key's blob is dropped.
	seen := map[string]bool{}
	for _, k := range manual {
		seen[keyBlob(k.Line)] = true
	}
	var desired []string
	desiredSet := map[string]bool{}
	for _, line := range lines {
		if _, err := parseKeyLine(line); err != nil {
			continue
		}
		b := keyBlob(line)
		if seen[b] {
			continue
		}
		seen[b] = true
		desired = append(desired, line)
		desiredSet[line] = true
	}
	same := len(managedNow) == len(desiredSet)
	if same {
		for l := range desiredSet {
			if !managedNow[l] {
				same = false
				break
			}
		}
	}
	if same {
		fileMu.Unlock()
		return
	}
	_ = ensureLayout()
	out := make([]string, 0, len(manual)+len(desired))
	for _, k := range manual {
		out = append(out, k.Line)
	}
	out = append(out, desired...)
	_ = writeKeysLocked(out)
	fileMu.Unlock()
	reloadRunning()
}

// keySet is what auth reads: enrolled keys, and the machine-only ones'
// devices, by wire blob.
type keySet struct {
	authorized  map[string]bool
	machineOnly map[string]string
}

func loadKeySet() keySet {
	fileMu.Lock()
	keys := listLocked()
	fileMu.Unlock()
	ks := keySet{authorized: map[string]bool{}, machineOnly: map[string]string{}}
	for _, k := range keys {
		pk, err := parseKeyLine(k.Line)
		if err != nil {
			continue
		}
		blob := string(pk.Marshal())
		ks.authorized[blob] = true
		if strings.HasPrefix(k.Comment, MachineKeyMarker) {
			ks.machineOnly[blob] = strings.TrimPrefix(k.Comment, MachineKeyMarker)
		}
	}
	return ks
}

func writeAtomic(p string, data []byte) error {
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, p); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}
