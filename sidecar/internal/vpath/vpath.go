// Package vpath is the one bidirectional mapper between real paths on
// this machine and the POSIX namespace Bromure AC sees: AC treats a Native
// Machine as a Linux guest whose home is /home/ubuntu.
//
//	Windows                     Virtual
//	%USERPROFILE%\x\y           /home/ubuntu/x/y
//	D:\src\proj                 /d/src/proj
//	%TEMP%\x                    /tmp/x            (Git Bash's /tmp)
//	\\server\share\…            refused (v1)
//
// On macOS and Linux only the home maps (the real home ↔ /home/ubuntu); every
// other absolute path is itself.
//
// Use it at every boundary: /state cwds, file ops, session JSON, the tmux
// shim's output, typed text, transcript paths, the delegation inbox.
package vpath

import (
	"errors"
	"os"
	"path"
	"path/filepath"
	"runtime"
	"strings"
	"unicode"
)

// GuestHome is the home Bromure AC names.
const GuestHome = "/home/ubuntu"

// ErrUNC is returned for a network path (\\server\share): not supported in v1.
var ErrUNC = errors.New("network paths (\\\\server\\share) aren't supported on this machine")

// ErrUnmappable is a virtual path with no real counterpart here.
var ErrUnmappable = errors.New("path has no counterpart on this machine")

// Mapper converts between real and virtual paths.
type Mapper struct {
	// Home is the real home (C:\Users\me, /Users/me).
	Home string
	// Temp is what /tmp is (Windows: %TEMP%, as Git Bash mounts it).
	Temp string
	// Windows selects drive-letter semantics (tests run both on any OS).
	Windows bool
}

var def *Mapper

// Default is the mapper for this machine.
func Default() *Mapper {
	if def == nil {
		home, _ := os.UserHomeDir()
		if runtime.GOOS == "windows" {
			if p := os.Getenv("USERPROFILE"); p != "" {
				home = p
			}
		}
		def = &Mapper{Home: filepath.Clean(home), Temp: os.TempDir(), Windows: runtime.GOOS == "windows"}
	}
	return def
}

// SetDefaultForTest replaces Default().
func SetDefaultForTest(m *Mapper) { def = m }

// --- Windows helpers -------------------------------------------------------

// winClean normalises a Windows path: forward slashes become backslashes,
// \\?\ and \??\ prefixes go, a drive letter is upper-cased, trailing
// separators are trimmed (but "C:\" stays).
func winClean(p string) string {
	p = strings.ReplaceAll(p, "/", `\`)
	for _, pre := range []string{`\\?\UNC\`, `\??\UNC\`} {
		if strings.HasPrefix(p, pre) {
			return `\\` + p[len(pre):]
		}
	}
	for _, pre := range []string{`\\?\`, `\??\`} {
		if strings.HasPrefix(p, pre) {
			p = p[len(pre):]
		}
	}
	if len(p) >= 2 && p[1] == ':' && isLetter(p[0]) {
		p = strings.ToUpper(p[:1]) + p[1:]
		if len(p) == 2 {
			p += `\`
		}
	}
	// Collapse runs of separators (not a leading \\ of a UNC path).
	var b strings.Builder
	for i := 0; i < len(p); i++ {
		if p[i] == '\\' && i > 1 && p[i-1] == '\\' {
			continue
		}
		b.WriteByte(p[i])
	}
	p = b.String()
	for len(p) > 3 && strings.HasSuffix(p, `\`) {
		p = p[:len(p)-1]
	}
	return p
}

func isLetter(c byte) bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') }

// hasPrefixFold: p == pre or p starts with pre + `\` (case-insensitive, as
// NTFS names are).
func hasPrefixFold(p, pre string) (rest string, ok bool) {
	if len(p) < len(pre) || !strings.EqualFold(p[:len(pre)], pre) {
		return "", false
	}
	rest = p[len(pre):]
	if rest == "" {
		return "", true
	}
	if rest[0] == '\\' {
		return rest[1:], true
	}
	if strings.HasSuffix(pre, `\`) { // pre is a drive root
		return rest, true
	}
	return "", false
}

// --- real → virtual --------------------------------------------------------

// ToVirtual maps a real path to what AC sees.
func (m *Mapper) ToVirtual(real string) (string, error) {
	if real == "" {
		return "", nil
	}
	if !m.Windows {
		real = path.Clean(real)
		if real == m.Home {
			return GuestHome, nil
		}
		if strings.HasPrefix(real, m.Home+"/") {
			return GuestHome + real[len(m.Home):], nil
		}
		return real, nil
	}
	p := winClean(real)
	if strings.HasPrefix(p, `\\`) {
		return "", ErrUNC
	}
	if rest, ok := hasPrefixFold(p, winClean(m.Home)); ok {
		if rest == "" {
			return GuestHome, nil
		}
		return GuestHome + "/" + strings.ReplaceAll(rest, `\`, "/"), nil
	}
	if m.Temp != "" {
		if rest, ok := hasPrefixFold(p, winClean(m.Temp)); ok {
			if rest == "" {
				return "/tmp", nil
			}
			return "/tmp/" + strings.ReplaceAll(rest, `\`, "/"), nil
		}
	}
	if len(p) >= 3 && p[1] == ':' && p[2] == '\\' && isLetter(p[0]) {
		rest := strings.ReplaceAll(p[3:], `\`, "/")
		v := "/" + strings.ToLower(p[:1])
		if rest != "" {
			v += "/" + rest
		}
		return v, nil
	}
	if strings.HasPrefix(p, "/") { // already POSIX (a path Git Bash printed)
		return p, nil
	}
	return "", ErrUnmappable
}

// MustVirtual is ToVirtual, the input itself on failure (for display).
func (m *Mapper) MustVirtual(real string) string {
	v, err := m.ToVirtual(real)
	if err != nil {
		return real
	}
	return v
}

// --- virtual → real --------------------------------------------------------

// ToReal maps a path AC sent to the real path. "~" and "~/x" are the home;
// a relative path is relative to the home (as the Swift Sidecar's expand).
func (m *Mapper) ToReal(v string) (string, error) {
	if !m.Windows {
		switch {
		case v == "" || v == "~":
			return m.Home, nil
		case strings.HasPrefix(v, "~/"):
			return m.Home + v[1:], nil
		case v == GuestHome:
			return m.Home, nil
		case strings.HasPrefix(v, GuestHome+"/"):
			return m.Home + v[len(GuestHome):], nil
		case strings.HasPrefix(v, "/"):
			return v, nil
		default:
			return m.Home + "/" + v, nil
		}
	}
	join := func(base, rest string) string {
		rest = strings.Trim(strings.ReplaceAll(rest, "/", `\`), `\`)
		if rest == "" {
			return base
		}
		if strings.HasSuffix(base, `\`) {
			return base + rest
		}
		return base + `\` + rest
	}
	switch {
	case v == "" || v == "~":
		return m.Home, nil
	case strings.HasPrefix(v, "~/"):
		return join(m.Home, v[2:]), nil
	case v == GuestHome:
		return m.Home, nil
	case strings.HasPrefix(v, GuestHome+"/"):
		return join(m.Home, v[len(GuestHome)+1:]), nil
	case v == "/tmp" || strings.HasPrefix(v, "/tmp/"):
		if m.Temp == "" {
			return "", ErrUnmappable
		}
		return join(winClean(m.Temp), strings.TrimPrefix(v, "/tmp")), nil
	case strings.HasPrefix(v, `\\`) || strings.HasPrefix(v, "//"):
		return "", ErrUNC
	case len(v) >= 2 && v[0] == '/' && isLetter(v[1]) && (len(v) == 2 || v[2] == '/'):
		return join(strings.ToUpper(v[1:2])+`:\`, v[2:]), nil
	case len(v) >= 2 && v[1] == ':' && isLetter(v[0]):
		return winClean(v), nil // already real
	case strings.HasPrefix(v, "/"):
		return "", ErrUnmappable
	default:
		return join(m.Home, v), nil
	}
}

// --- text ------------------------------------------------------------------

// MSYSHome is the home as Git Bash writes it (/c/Users/me); the real home
// elsewhere.
func (m *Mapper) MSYSHome() string {
	if !m.Windows {
		return m.Home
	}
	p := winClean(m.Home)
	if len(p) >= 3 && p[1] == ':' {
		return "/" + strings.ToLower(p[:1]) + strings.ReplaceAll(strings.TrimSuffix(p[2:], `\`), `\`, "/")
	}
	return strings.ReplaceAll(p, `\`, "/")
}

// MapForBash is shell text bound for Git Bash: only /home/ubuntu changes
// (MSYS already understands /d/...). On macOS/Linux, the real home.
func (m *Mapper) MapForBash(text string) string {
	return strings.ReplaceAll(text, GuestHome, m.MSYSHome())
}

// MapTextToReal is text a native program reads (a message typed into an
// agent, a path handed to claude.exe): every /home/ubuntu path becomes the
// real one. On Windows the separators inside each such path token become
// backslashes, up to the first space, quote or bracket (what follows keeps
// its forward slashes, which Windows accepts too).
func (m *Mapper) MapTextToReal(text string) string {
	if !m.Windows {
		return strings.ReplaceAll(text, GuestHome, m.Home)
	}
	home := winClean(m.Home)
	var b strings.Builder
	for {
		i := strings.Index(text, GuestHome)
		if i < 0 {
			b.WriteString(text)
			return b.String()
		}
		// A match inside a longer name (/home/ubuntu2) isn't the home.
		end := i + len(GuestHome)
		if end < len(text) && !isPathEnd(text[end]) && text[end] != '/' {
			b.WriteString(text[:end])
			text = text[end:]
			continue
		}
		b.WriteString(text[:i])
		b.WriteString(home)
		j := end
		for j < len(text) && !isPathEnd(text[j]) {
			j++
		}
		b.WriteString(strings.ReplaceAll(text[end:j], "/", `\`))
		text = text[j:]
	}
}

func isPathEnd(c byte) bool {
	switch c {
	case ' ', '\t', '\n', '\r', '"', '\'', '`', ')', ']', '>', '<', ',', ';', '|':
		return true
	}
	return false
}

// MapTextToVirtual is the inverse for text AC reads (tmux shim output,
// transcripts' paths): the real home becomes /home/ubuntu, drive paths
// /c/...; on Windows only whole path tokens are touched.
func (m *Mapper) MapTextToVirtual(text string) string {
	if !m.Windows {
		return strings.ReplaceAll(text, m.Home, GuestHome)
	}
	home := winClean(m.Home)
	var b strings.Builder
	for {
		i := indexFold(text, home)
		if i < 0 {
			b.WriteString(text)
			return b.String()
		}
		j := i + len(home)
		if j < len(text) && text[j] != '\\' && text[j] != '/' && !isPathEnd(text[j]) {
			b.WriteString(text[:j])
			text = text[j:]
			continue
		}
		b.WriteString(text[:i])
		k := j
		for k < len(text) && !isPathEnd(text[k]) {
			k++
		}
		b.WriteString(GuestHome + strings.ReplaceAll(text[j:k], `\`, "/"))
		text = text[k:]
	}
}

func indexFold(s, sub string) int {
	if sub == "" {
		return -1
	}
	ls, lsub := strings.ToLower(s), strings.ToLower(sub)
	// ToLower may change byte lengths for non-ASCII; fall back to exact.
	if len(ls) != len(s) || len(lsub) != len(sub) {
		return strings.Index(s, sub)
	}
	return strings.Index(ls, lsub)
}

// --- AC's cwd filter -------------------------------------------------------

// ErrUnsupportedChars is a folder AC can't splice into its shell lines.
var ErrUnsupportedChars = errors.New("folder name has characters Bromure AC can't use (only letters, digits, space and -_./+)")

// CheckCwd mirrors AgentSessionLocator.sanitized (CodingTasks.swift):
// ASCII letters, digits and -_./+ and space, any non-ASCII letter-ish
// character, and no control or line-separator character anywhere.
func CheckCwd(v string) error {
	if v == "" {
		return ErrUnsupportedChars
	}
	for _, r := range v {
		if r < 0x80 {
			c := byte(r)
			if isLetter(c) || (c >= '0' && c <= '9') || strings.IndexByte("-_./+ ", c) >= 0 {
				continue
			}
			return ErrUnsupportedChars
		}
		if unicode.IsControl(r) || r == '\u2028' || r == '\u2029' || r == '\u0085' || r == unicode.ReplacementChar {
			return ErrUnsupportedChars
		}
	}
	return nil
}

// MapOutput is a command's stdout on its way back to AC: the home in
// every form a tool here prints it (Git Bash's /c/Users/me, git's
// C:/Users/me, a native C:\Users\me) becomes /home/ubuntu, when it is a
// whole path prefix. Elsewhere, the real home.
func (m *Mapper) MapOutput(text string) string {
	if !m.Windows {
		if m.Home == "" || m.Home == GuestHome {
			return text
		}
		return replacePrefixFold(text, m.Home, false)
	}
	home := winClean(m.Home)
	for _, form := range []string{m.MSYSHome(), strings.ReplaceAll(home, `\`, "/"), home} {
		text = replacePrefixFold(text, form, true)
	}
	return text
}

// replacePrefixFold swaps each occurrence of prefix (followed by a
// separator or a path end) for GuestHome; separators after it become '/'
// on Windows only within the same token.
func replacePrefixFold(text, prefix string, windows bool) string {
	if prefix == "" {
		return text
	}
	var b strings.Builder
	for {
		i := -1
		if windows {
			i = indexFold(text, prefix)
		} else {
			i = strings.Index(text, prefix)
		}
		if i < 0 {
			b.WriteString(text)
			return b.String()
		}
		j := i + len(prefix)
		if j < len(text) && text[j] != '/' && text[j] != '\\' && !isPathEnd(text[j]) && text[j] != ':' {
			b.WriteString(text[:j])
			text = text[j:]
			continue
		}
		b.WriteString(text[:i])
		b.WriteString(GuestHome)
		if windows {
			k := j
			for k < len(text) && !isPathEnd(text[k]) {
				k++
			}
			b.WriteString(strings.ReplaceAll(text[j:k], `\`, "/"))
			text = text[k:]
		} else {
			text = text[j:]
		}
	}
}
