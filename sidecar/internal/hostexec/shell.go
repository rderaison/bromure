package hostexec

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"

	"github.com/rderaison/bromure/sidecar/internal/paths"
	"github.com/rderaison/bromure/sidecar/internal/settings"
	"github.com/rderaison/bromure/sidecar/internal/vpath"
)

// Shell is the POSIX shell every client command runs under: Git for
// Windows' bash on Windows, /bin/bash elsewhere.
type Shell struct {
	// Bash runs commands (Windows: <git>\usr\bin\bash.exe, which starts
	// faster than the bin\ launcher; the PATH below gives it its tools).
	Bash string
	// Launcher is what Claude Code's CLAUDE_CODE_GIT_BASH_PATH names
	// (<git>\bin\bash.exe on Windows; Bash elsewhere).
	Launcher string
	// Root is the Git for Windows install ("" elsewhere).
	Root string
}

var (
	shellMu    sync.Mutex
	shellCache *Shell
	shellMiss  bool
)

// FindShell locates bash; nil when there is none (Windows without Git for
// Windows). Looked up once, again after Rescan.
func FindShell() *Shell {
	shellMu.Lock()
	defer shellMu.Unlock()
	if shellCache != nil || shellMiss {
		return shellCache
	}
	shellCache = findShell()
	shellMiss = shellCache == nil
	return shellCache
}

// Rescan forgets the cached lookup (after the user installed Git).
func Rescan() {
	shellMu.Lock()
	shellCache, shellMiss = nil, false
	shellMu.Unlock()
}

func findShell() *Shell {
	if runtime.GOOS != "windows" {
		for _, p := range []string{"/bin/bash", "/usr/bin/bash", "/usr/local/bin/bash", "/opt/homebrew/bin/bash"} {
			if isFile(p) {
				return &Shell{Bash: p, Launcher: p}
			}
		}
		return nil
	}
	// 1. The CLAUDE_CODE_GIT_BASH_PATH setting (or the variable itself).
	for _, p := range []string{settings.String(settings.GitBashPath, ""), os.Getenv("CLAUDE_CODE_GIT_BASH_PATH")} {
		if p != "" && isFile(p) {
			if s := shellFromBash(p); s != nil {
				return s
			}
		}
	}
	// 2. Git for Windows' InstallPath (machine, then per-user install).
	for _, root := range gitInstallRoots() {
		if s := shellFromRoot(root); s != nil {
			return s
		}
	}
	// 3. `where git` → its install.
	if git, err := lookPathIn("git", os.Getenv("PATH")); err == nil {
		dir := filepath.Dir(git)
		for _, up := range []string{"..", filepath.Join("..", "..")} {
			if s := shellFromRoot(filepath.Clean(filepath.Join(dir, up))); s != nil {
				return s
			}
		}
	}
	// 4. The usual places.
	for _, root := range []string{
		filepath.Join(os.Getenv("ProgramFiles"), "Git"),
		filepath.Join(os.Getenv("LOCALAPPDATA"), "Programs", "Git"),
		filepath.Join(paths.Home(), "scoop", "apps", "git", "current"),
	} {
		if s := shellFromRoot(root); s != nil {
			return s
		}
	}
	return nil
}

func shellFromRoot(root string) *Shell {
	if root == "" {
		return nil
	}
	usr := filepath.Join(root, "usr", "bin", "bash.exe")
	bin := filepath.Join(root, "bin", "bash.exe")
	if !isFile(usr) && !isFile(bin) {
		return nil
	}
	s := &Shell{Root: root, Bash: usr, Launcher: bin}
	if !isFile(usr) {
		s.Bash = bin
	}
	if !isFile(bin) {
		s.Launcher = s.Bash
	}
	return s
}

// shellFromBash takes a bash.exe path (either launcher) to its install.
func shellFromBash(p string) *Shell {
	dir := filepath.Dir(p)
	if strings.EqualFold(filepath.Base(dir), "bin") {
		parent := filepath.Dir(dir)
		if strings.EqualFold(filepath.Base(parent), "usr") {
			parent = filepath.Dir(parent)
		}
		if s := shellFromRoot(parent); s != nil {
			s.Launcher = p
			return s
		}
	}
	return &Shell{Bash: p, Launcher: p}
}

func isFile(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}

// --- environment -----------------------------------------------------------

// pathSep is the PATH list separator.
var pathSep = string(os.PathListSeparator)

// CommandEnv is the environment of everything run for a client: the
// user's own environment (their PATH, so git, claude, node resolve as in
// their terminal) behind our bin/ of shims, with Git Bash's tools next on
// Windows.
func CommandEnv() []string {
	m := envMap(os.Environ())
	userPath := m.get("PATH")
	sh := FindShell()
	mapper := vpath.Default()
	parts := []string{paths.BinDir()}
	if runtime.GOOS == "windows" {
		if sh != nil && sh.Root != "" {
			parts = append(parts, filepath.Join(sh.Root, "usr", "bin"), filepath.Join(sh.Root, "mingw64", "bin"))
			if runtime.GOARCH == "arm64" {
				parts = append(parts, filepath.Join(sh.Root, "clangarm64", "bin"))
			}
		}
		m.set("HOME", mapper.MSYSHome())
		// Links Git Bash makes are real NTFS symlinks (or fail), never copies.
		m.set("MSYS", "winsymlinks:nativestrict")
		// MSYS path mangling of arguments breaks the client's scripts.
		m.set("MSYS_NO_PATHCONV", "1")
		m.set("MSYS2_ARG_CONV_EXCL", "*")
		m.set("CHERE_INVOKING", "1")
		if m.get("MSYSTEM") == "" {
			m.set("MSYSTEM", "MINGW64")
		}
		// …but git.exe is native and then gets /c/... unconverted, which
		// it can't open: bash-env.sh wraps `git` to convert its path
		// arguments (a function: no extra process per call).
		m.set("BASH_ENV", BashEnvFile())
		if sh != nil {
			m.set("BROMURE_GIT_BASH", sh.Bash)
			m.set("CLAUDE_CODE_GIT_BASH_PATH", sh.Launcher)
		}
	} else {
		m.set("HOME", paths.Home())
		if m.get("SHELL") == "" {
			m.set("SHELL", "/bin/bash")
		}
	}
	if userPath != "" {
		parts = append(parts, userPath)
	}
	m.set("PATH", strings.Join(parts, pathSep))
	if m.get("LANG") == "" {
		m.set("LANG", "en_US.UTF-8")
	}
	m.set("TERM", "xterm-256color")
	m.set("BROMURE_SIDECAR", StableExecutable())
	m.set("BROMURE_CONTROL", paths.ControlSocket())
	// Never inherited by the shell: a stray TMUX would point clients at a
	// real tmux server.
	m.del("TMUX")
	return m.list()
}

// StableExecutable is what agents call back into (hooks, the delegation
// MCP): bin/bromure-sidecar[.exe], a copy (or link) of this binary
// refreshed at every daemon start, so an agent that outlives an update
// never calls a path that's gone.
func StableExecutable() string {
	return filepath.Join(paths.BinDir(), paths.ExeName("bromure-sidecar"))
}

// envMap is a case-insensitive (on Windows) environment.
type envList struct {
	keys []string
	vals map[string]string
	fold bool
}

func envMap(env []string) *envList {
	e := &envList{vals: map[string]string{}, fold: runtime.GOOS == "windows"}
	for _, kv := range env {
		i := strings.IndexByte(kv, '=')
		if i <= 0 { // Windows' "=C:=C:\x" entries
			continue
		}
		e.set(kv[:i], kv[i+1:])
	}
	return e
}

func (e *envList) norm(k string) string {
	if e.fold {
		return strings.ToUpper(k)
	}
	return k
}

func (e *envList) get(k string) string { return e.vals[e.norm(k)] }

func (e *envList) set(k, v string) {
	n := e.norm(k)
	if _, ok := e.vals[n]; !ok {
		e.keys = append(e.keys, k)
	}
	e.vals[n] = v
}

func (e *envList) del(k string) {
	n := e.norm(k)
	delete(e.vals, n)
	for i, key := range e.keys {
		if e.norm(key) == n {
			e.keys = append(e.keys[:i], e.keys[i+1:]...)
			break
		}
	}
}

func (e *envList) list() []string {
	out := make([]string, 0, len(e.keys))
	for _, k := range e.keys {
		out = append(out, k+"="+e.vals[e.norm(k)])
	}
	return out
}

// EnvGet reads one variable out of an environment list.
func EnvGet(env []string, key string) string { return envMap(env).get(key) }

// EnvSet returns env with key=value set.
func EnvSet(env []string, key, value string) []string {
	m := envMap(env)
	m.set(key, value)
	return m.list()
}

// --- lookup ----------------------------------------------------------------

// LookPath resolves a program on the command environment's PATH (PATHEXT
// on Windows).
func LookPath(name string, env []string) (string, error) {
	return lookPathIn(name, EnvGet(env, "PATH"))
}

func lookPathIn(name, pathList string) (string, error) {
	if strings.ContainsAny(name, `/\`) {
		if p := withExt(name); p != "" {
			return p, nil
		}
		return "", os.ErrNotExist
	}
	for _, dir := range filepath.SplitList(pathList) {
		if dir == "" {
			continue
		}
		if p := withExt(filepath.Join(dir, name)); p != "" {
			return p, nil
		}
	}
	return "", os.ErrNotExist
}

func withExt(p string) string {
	if runtime.GOOS != "windows" {
		if st, err := os.Stat(p); err == nil && !st.IsDir() && st.Mode()&0o111 != 0 {
			return p
		}
		return ""
	}
	if filepath.Ext(p) != "" && isFile(p) {
		return p
	}
	exts := os.Getenv("PATHEXT")
	if exts == "" {
		exts = ".COM;.EXE;.BAT;.CMD"
	}
	for _, ext := range strings.Split(exts, ";") {
		if ext != "" && isFile(p+strings.ToLower(ext)) {
			return p + strings.ToLower(ext)
		}
	}
	return ""
}

// BashEnvFile is the prelude every non-interactive bash here sources
// (BASH_ENV): Windows only.
func BashEnvFile() string { return filepath.Join(paths.BinDir(), "bash-env.sh") }

// bashEnv converts git's MSYS path arguments (/c/x → C:/x, --opt=/c/x)
// for the native git.exe, since MSYS_NO_PATHCONV keeps MSYS from doing it.
const bashEnv = `# Generated by Bromure Sidecar; rewritten at every start.
git() {
  local a out=()
  for a in "$@"; do
    if [[ $a =~ ^/([a-zA-Z])(/.*)?$ ]]; then a="${BASH_REMATCH[1]}:${BASH_REMATCH[2]:-/}"
    elif [[ $a =~ ^(--[a-z-]+=)/([a-zA-Z])(/.*)?$ ]]; then a="${BASH_REMATCH[1]}${BASH_REMATCH[2]}:${BASH_REMATCH[3]:-/}"
    elif [[ $a == /tmp || $a == /tmp/* ]]; then a="$(cygpath -m "$a")"
    fi
    out+=("$a")
  done
  command git "${out[@]}"
}
`

// WriteBashEnv (re)writes the prelude.
func WriteBashEnv() error {
	if runtime.GOOS != "windows" {
		return nil
	}
	return os.WriteFile(BashEnvFile(), []byte(bashEnv), 0o644)
}

// AgentEnv is the environment an agent's window starts with: the user's
// own (nothing of the exec environment's MSYS settings, which would change
// how the agent's own Bash tool behaves), plus Git Bash for Claude Code and
// the Sidecar's own variables.
func AgentEnv() []string {
	m := envMap(os.Environ())
	m.del("TMUX")
	m.del("TMUX_PANE")
	if sh := FindShell(); sh != nil && runtime.GOOS == "windows" {
		m.set("CLAUDE_CODE_GIT_BASH_PATH", sh.Launcher)
	}
	if m.get("LANG") == "" {
		m.set("LANG", "en_US.UTF-8")
	}
	m.set("TERM", "xterm-256color")
	m.set("COLORTERM", "truecolor")
	m.set("BROMURE_SIDECAR", StableExecutable())
	m.set("BROMURE_CONTROL", paths.ControlSocket())
	return m.list()
}

// EnvDel returns env without key (an empty value still counts as set to
// MSYS).
func EnvDel(env []string, key string) []string {
	m := envMap(env)
	m.del(key)
	return m.list()
}
