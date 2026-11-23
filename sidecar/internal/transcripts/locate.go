package transcripts

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/paths"
)

// Where is what the locator knows about a window's agent.
type Where struct {
	Tool string
	// Cwd is the real folder the agent runs in.
	Cwd string
	// Pinned is the transcript the agent itself reported (Claude's hook),
	// real path; it wins when it exists and is newer than the floor.
	Pinned string
	// SessionID is the agent's own conversation id when known (Claude's
	// session_id, a Codex/Grok/omp UUID, a Kimi session_…).
	SessionID string
	// Since is the floor: a transcript last written before it belongs to
	// an earlier run. Zero: no floor (a resumed agent).
	Since time.Time
}

// floorOK: modified at or after the floor (a day's slack below the epoch
// like the client's findEpoch is moot here: zero means none).
func floorOK(p string, since time.Time) bool {
	st, err := os.Stat(p)
	if err != nil || st.IsDir() {
		return false
	}
	return since.IsZero() || !st.ModTime().Before(since)
}

// Locate is the transcript a window's agent is writing (real path), and
// pending reports a pinned file that doesn't exist yet (a fresh Claude
// before its first prompt): the chat stays empty rather than showing the
// folder's newest file, which may be another session's.
func Locate(w Where) (path string, pending bool) {
	if w.Pinned != "" {
		if floorOK(w.Pinned, w.Since) {
			return w.Pinned, false
		}
		if _, err := os.Stat(w.Pinned); err != nil {
			return "", true
		}
	}
	switch w.Tool {
	case "claude":
		return claude(w), false
	case "codex":
		return codex(w), false
	case "grok":
		return grok(w), false
	case "kimi":
		return kimi(w), false
	case "omp":
		return omp(w), false
	}
	// Unknown: every store, the newest wins.
	var best string
	var bestT time.Time
	for _, f := range []func(Where) string{claude, codex, grok, kimi, omp} {
		if p := f(w); p != "" {
			if st, err := os.Stat(p); err == nil && (best == "" || st.ModTime().After(bestT)) {
				best, bestT = p, st.ModTime()
			}
		}
	}
	return best, false
}

// newestIn: the newest file among dirs' entries matching ok, past the floor.
func newestIn(since time.Time, dirs []string, ok func(name string) bool) string {
	var best string
	var bestT time.Time
	seen := map[string]bool{}
	for _, d := range dirs {
		if d == "" || seen[d] {
			continue
		}
		seen[d] = true
		items, err := os.ReadDir(d)
		if err != nil {
			continue
		}
		for _, it := range items {
			if it.IsDir() || !ok(it.Name()) {
				continue
			}
			info, err := it.Info()
			if err != nil || (!since.IsZero() && info.ModTime().Before(since)) {
				continue
			}
			if best == "" || info.ModTime().After(bestT) {
				best, bestT = filepath.Join(d, it.Name()), info.ModTime()
			}
		}
	}
	return best
}

func resolved(p string) string {
	if r, err := filepath.EvalSymlinks(p); err == nil {
		return r
	}
	return p
}

// --- Claude Code -----------------------------------------------------------

// ClaudeDir is a folder's project directory name: every character
// outside [a-zA-Z0-9] becomes '-' (per UTF-16 unit, as its JavaScript
// does): C:\Users\me\src\x → C--Users-me-src-x.
func ClaudeDir(p string) string {
	var b strings.Builder
	for _, r := range p {
		switch {
		case (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9'):
			b.WriteRune(r)
		case r > 0xffff:
			b.WriteString("--")
		default:
			b.WriteByte('-')
		}
	}
	return b.String()
}

func claude(w Where) string {
	base := filepath.Join(paths.Home(), ".claude", "projects")
	dirs := []string{filepath.Join(base, ClaudeDir(w.Cwd)), filepath.Join(base, ClaudeDir(resolved(w.Cwd)))}
	if w.SessionID != "" {
		for _, d := range dirs {
			if p := filepath.Join(d, w.SessionID+".jsonl"); floorOK(p, time.Time{}) {
				return p
			}
		}
	}
	return newestIn(w.Since, dirs, func(n string) bool { return strings.HasSuffix(n, ".jsonl") })
}

// --- Codex -----------------------------------------------------------------

var uuidRe = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// codexRollouts lists ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl newest
// first (at most n, past the floor).
func codexRollouts(since time.Time, n int) []string {
	root := filepath.Join(paths.Home(), ".codex", "sessions")
	type f struct {
		p string
		t time.Time
	}
	var all []f
	_ = filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasPrefix(d.Name(), "rollout-") || !strings.HasSuffix(d.Name(), ".jsonl") {
			return nil
		}
		info, err := d.Info()
		if err == nil && (since.IsZero() || !info.ModTime().Before(since)) {
			all = append(all, f{p, info.ModTime()})
		}
		return nil
	})
	for i := 1; i < len(all); i++ {
		for j := i; j > 0 && all[j].t.After(all[j-1].t); j-- {
			all[j], all[j-1] = all[j-1], all[j]
		}
	}
	out := []string{}
	for i := 0; i < len(all) && i < n; i++ {
		out = append(out, all[i].p)
	}
	return out
}

func codex(w Where) string {
	if uuidRe.MatchString(w.SessionID) {
		for _, p := range codexRollouts(time.Time{}, 1<<30) {
			if strings.HasSuffix(p, w.SessionID+".jsonl") {
				return p
			}
		}
	}
	// Line 1 (session_meta) records the cwd as JSON: match either path.
	needles := [][]byte{}
	for _, c := range []string{w.Cwd, resolved(w.Cwd)} {
		js, _ := json.Marshal(c)
		needles = append(needles, append([]byte(`"cwd":`), js...))
	}
	for _, p := range codexRollouts(w.Since, 24) {
		fh, err := os.Open(p)
		if err != nil {
			continue
		}
		head := make([]byte, 8192)
		n, _ := bufio.NewReader(fh).Read(head)
		fh.Close()
		for _, nd := range needles {
			if strings.Contains(string(head[:n]), string(nd)) {
				return p
			}
		}
	}
	return ""
}

// --- Grok ------------------------------------------------------------------

// GrokEncode is RFC 3986 percent-encoding with an empty safe set.
func GrokEncode(s string) string {
	var b strings.Builder
	for _, c := range []byte(s) {
		if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || strings.IndexByte("-._~", c) >= 0 {
			b.WriteByte(c)
		} else {
			b.WriteString("%" + strings.ToUpper(hex.EncodeToString([]byte{c})))
		}
	}
	return b.String()
}

func grok(w Where) string {
	base := filepath.Join(paths.Home(), ".grok", "sessions")
	if uuidRe.MatchString(w.SessionID) {
		matches, _ := filepath.Glob(filepath.Join(base, "*", w.SessionID, "updates.jsonl"))
		if len(matches) > 0 {
			return matches[0]
		}
	}
	var best string
	var bestT time.Time
	for _, c := range []string{w.Cwd, resolved(w.Cwd)} {
		d := filepath.Join(base, GrokEncode(c))
		items, _ := os.ReadDir(d)
		for _, it := range items {
			p := filepath.Join(d, it.Name(), "updates.jsonl")
			if st, err := os.Stat(p); err == nil && (w.Since.IsZero() || !st.ModTime().Before(w.Since)) {
				if best == "" || st.ModTime().After(bestT) {
					best, bestT = p, st.ModTime()
				}
			}
		}
	}
	return best
}

// --- Kimi ------------------------------------------------------------------

// KimiSlug is Kimi Code's slugifyWorkDirName.
func KimiSlug(name string) string {
	var b strings.Builder
	inRun := false
	for _, r := range strings.ToLower(name) {
		keep := (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '.' || r == '_' || r == '-'
		if keep {
			b.WriteRune(r)
			inRun = false
		} else if !inRun {
			b.WriteByte('-')
			inRun = true
		}
	}
	slug := strings.Trim(b.String(), "-")
	if len(slug) > 40 {
		slug = slug[:40]
	}
	slug = strings.Trim(slug, "-")
	if slug == "" || slug == "." || slug == ".." {
		return "workspace"
	}
	return slug
}

// KimiKey is a working directory's session bucket.
func KimiKey(p string) string {
	p = strings.ReplaceAll(p, `\`, "/")
	for strings.HasSuffix(p, "/") {
		p = p[:len(p)-1]
	}
	parts := strings.Split(p, "/")
	sum := sha256.Sum256([]byte(p))
	return "wd_" + KimiSlug(parts[len(parts)-1]) + "_" + hex.EncodeToString(sum[:])[:12]
}

var kimiSessionRe = regexp.MustCompile(`^session_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

func kimi(w Where) string {
	base := filepath.Join(paths.Home(), ".kimi-code", "sessions")
	journal := func(sessionDir string) string {
		for _, p := range []string{filepath.Join(sessionDir, "agents", "main", "wire.jsonl"), filepath.Join(sessionDir, "wire.jsonl")} {
			if _, err := os.Stat(p); err == nil {
				return p
			}
		}
		return ""
	}
	if kimiSessionRe.MatchString(w.SessionID) {
		matches, _ := filepath.Glob(filepath.Join(base, "wd_*", w.SessionID))
		for _, m := range matches {
			if j := journal(m); j != "" {
				return j
			}
		}
	}
	var buckets []string
	for _, c := range []string{w.Cwd, resolved(w.Cwd)} {
		buckets = append(buckets, filepath.Join(base, KimiKey(c)))
		slug := KimiSlug(filepath.Base(c))
		g, _ := filepath.Glob(filepath.Join(base, "wd_"+slug+"_*"))
		buckets = append(buckets, g...)
	}
	var best string
	var bestT time.Time
	seen := map[string]bool{}
	for _, b := range buckets {
		if seen[b] {
			continue
		}
		seen[b] = true
		items, _ := os.ReadDir(b)
		for _, it := range items {
			if !it.IsDir() {
				continue
			}
			j := journal(filepath.Join(b, it.Name()))
			if j == "" {
				continue
			}
			if st, err := os.Stat(j); err == nil && (w.Since.IsZero() || !st.ModTime().Before(w.Since)) {
				if best == "" || st.ModTime().After(bestT) {
					best, bestT = j, st.ModTime()
				}
			}
		}
	}
	return best
}

// --- omp -------------------------------------------------------------------

// OmpDir is omp's session folder name for a cwd: home-relative ("-proj"),
// temp-relative ("-tmp-x") or absolute ("--C-src-x--"), with separators
// and ':' as '-'.
func OmpDir(cwd string) string {
	flat := func(s string) string {
		return strings.Map(func(r rune) rune {
			if r == '/' || r == '\\' || r == ':' {
				return '-'
			}
			return r
		}, s)
	}
	home := paths.Home()
	tmp := os.TempDir()
	eq := func(a, b string) bool { return strings.EqualFold(filepath.Clean(a), filepath.Clean(b)) }
	under := func(p, base string) (string, bool) {
		rel, err := filepath.Rel(base, p)
		if err != nil || strings.HasPrefix(rel, "..") || rel == "." {
			return "", false
		}
		return rel, true
	}
	switch {
	case eq(cwd, home):
		return "-"
	case func() bool { _, ok := under(cwd, home); return ok }():
		rel, _ := under(cwd, home)
		return "-" + flat(rel)
	case eq(cwd, tmp):
		return "-tmp"
	case func() bool { _, ok := under(cwd, tmp); return ok }():
		rel, _ := under(cwd, tmp)
		return "-tmp-" + flat(rel)
	}
	abs := strings.TrimLeft(cwd, `/\`)
	return "--" + flat(abs) + "--"
}

func omp(w Where) string {
	base := os.Getenv("PI_CODING_AGENT_DIR")
	if base == "" {
		base = filepath.Join(paths.Home(), ".omp", "agent")
	}
	base = filepath.Join(base, "sessions")
	if uuidRe.MatchString(w.SessionID) {
		matches, _ := filepath.Glob(filepath.Join(base, "*", "*_"+w.SessionID+".jsonl"))
		if len(matches) > 0 {
			return matches[0]
		}
	}
	isJSONL := func(n string) bool { return strings.HasSuffix(n, ".jsonl") }
	if p := newestIn(w.Since, []string{filepath.Join(base, OmpDir(w.Cwd)), filepath.Join(base, OmpDir(resolved(w.Cwd)))}, isJSONL); p != "" {
		return p
	}
	if w.Since.IsZero() {
		return ""
	}
	// omp doesn't always keep the tab's folder as its cwd: the newest omp
	// session anywhere past the floor (the agent's own start) is its own.
	items, _ := os.ReadDir(base)
	var dirs []string
	for _, it := range items {
		if it.IsDir() {
			dirs = append(dirs, filepath.Join(base, it.Name()))
		}
	}
	return newestIn(w.Since, dirs, isJSONL)
}
