// Package shims holds the `tmux` and `ps` emulators Bromure AC's commands
// meet on a Native Machine (bin/tmux → `bromure-sidecar __tmux`, bin/ps →
// `bromure-sidecar __ps`). They answer from the pane host (panes.Client)
// and print what tmux 3.4 and procps print, because the client parses
// that output with awk, grep and cut written for a Linux guest.
package shims

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/user"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/panes"
	"github.com/rderaison/bromure/sidecar/internal/paths"
)

const tmuxVersion = "3.4"

// errQuiet is a failure already reported (or silent by design, -q).
var errQuiet = errors.New("")

// tmuxError is one line on stderr, exit 1.
type tmuxError string

func (e tmuxError) Error() string { return string(e) }

func errf(format string, a ...any) error { return tmuxError(fmt.Sprintf(format, a...)) }

// tmuxRun is one invocation of the shim.
type tmuxRun struct {
	c      panes.Client
	stdin  io.Reader
	stdout io.Writer
	stderr io.Writer
	getenv func(string) string
	utf8   bool
	socket string

	wins     []panes.Window // List(true), cached until a command changes them
	winsErr  error
	winsOK   bool
	cls      []panes.ClientInfo
	clsOK    bool
	host     string
	store    *optStore
	attachTo *int // new-session/attach-session: attach once the list ran
	attachRO bool
	onLookup func(name string) // tests: every variable a format asks for
}

// RunTmux runs one tmux command line (argv without "tmux") and returns
// the exit status. c may be nil when the pane host can't be reached.
func RunTmux(c panes.Client, args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	logx.Quiet()
	r := &tmuxRun{c: c, stdin: stdin, stdout: stdout, stderr: stderr, getenv: osGetenv, socket: "default"}
	return r.main(args)
}

func (r *tmuxRun) socketPath() string {
	if strings.Contains(r.socket, "/") {
		return r.socket
	}
	return "/tmp/tmux-1000/" + r.socket
}

const tmuxUsage = "usage: tmux [-2CDhlNuVv] [-c shell-command] [-f file] [-L socket-name]\n" +
	"            [-S socket-path] [-T features] [command [flags]]"

func (r *tmuxRun) main(args []string) int {
	flagU := false
	i := 0
global:
	for i < len(args) {
		a := args[i]
		if a == "--" {
			i++
			break
		}
		if len(a) < 2 || a[0] != '-' {
			break
		}
		for j := 1; j < len(a); j++ {
			switch a[j] {
			case 'u':
				flagU = true
			case '2', 'D', 'd', 'l', 'N', 'q', 'v', 'U', 'C':
				// accepted, no effect here (-C control mode isn't served)
			case 'h':
				fmt.Fprintln(r.stderr, tmuxUsage)
				return 0
			case 'V':
				fmt.Fprintln(r.stdout, "tmux "+tmuxVersion)
				return 0
			case 'L', 'S', 'f', 'T', 'c':
				val := a[j+1:]
				if val == "" {
					if i+1 >= len(args) {
						fmt.Fprintln(r.stderr, tmuxUsage)
						return 1
					}
					i++
					val = args[i]
				}
				switch a[j] {
				case 'L', 'S':
					r.socket = val
				case 'c':
					fmt.Fprintln(r.stderr, "unknown command: -c (shell-command mode isn't supported here)")
					logUnknown("tmux", "-c")
					return 1
				}
				i++
				continue global
			default:
				fmt.Fprintln(r.stderr, tmuxUsage)
				return 1
			}
		}
		i++
	}
	r.utf8 = clientIsUTF8(flagU, r.getenv)
	rest := args[i:]
	if len(rest) == 0 {
		rest = []string{"new-session"}
	}
	cmds, err := r.parseList(rest)
	if err != nil {
		r.printErr(err)
		return 1
	}
	status := 0
	for _, pc := range cmds {
		if err := pc.spec.run(r, pc.args); err != nil {
			r.printErr(err)
			status = 1
			break // tmux drops the rest of the group after an error
		}
	}
	if status == 0 && r.attachTo != nil {
		return r.attach(*r.attachTo, r.attachRO)
	}
	return status
}

func (r *tmuxRun) printErr(err error) {
	if err == nil || err == errQuiet || err.Error() == "" {
		return
	}
	fmt.Fprintln(r.stderr, err.Error())
}

// println prints one line the way cmdq_print does.
func (r *tmuxRun) println(s string) {
	s = visEscape(s)
	if !r.utf8 {
		s = sanitizeASCII(s)
	}
	io.WriteString(r.stdout, s+"\n")
}

// --- the pane host, cached --------------------------------------------------

var errNoServer = errors.New("no server")

func (r *tmuxRun) noServer() error {
	return errf("no server running on %s", r.socketPath())
}

func (r *tmuxRun) all() ([]panes.Window, error) {
	if !r.winsOK {
		r.winsOK = true
		if r.c == nil {
			r.winsErr = errNoServer
		} else {
			ws, err := r.c.List(true)
			if err != nil {
				r.winsErr = errNoServer
			} else {
				sort.Slice(ws, func(a, b int) bool { return ws[a].Index < ws[b].Index })
				r.wins = ws
			}
		}
	}
	if r.winsErr != nil {
		return nil, r.noServer()
	}
	return r.wins, nil
}

// visible is the session's windows (hidden ones left out).
func (r *tmuxRun) visible() ([]panes.Window, error) {
	ws, err := r.all()
	if err != nil {
		return nil, err
	}
	out := make([]panes.Window, 0, len(ws))
	for _, w := range ws {
		if !w.Hidden {
			out = append(out, w)
		}
	}
	return out, nil
}

func (r *tmuxRun) invalidate() { r.winsOK, r.winsErr, r.wins, r.clsOK = false, nil, nil, false }

func (r *tmuxRun) clients() ([]panes.ClientInfo, error) {
	if !r.clsOK {
		if r.c == nil {
			return nil, r.noServer()
		}
		cs, err := r.c.ListClients()
		if err != nil {
			return nil, r.noServer()
		}
		sort.SliceStable(cs, func(a, b int) bool { return cs[a].ID < cs[b].ID })
		r.cls, r.clsOK = cs, true
	}
	return r.cls, nil
}

func (r *tmuxRun) hostname() string {
	if r.host == "" {
		r.host, _ = os.Hostname()
		if r.host == "" {
			r.host = "localhost"
		}
	}
	return r.host
}

func (r *tmuxRun) sessionCreated() string {
	ws, _ := r.all()
	var first time.Time
	for _, w := range ws {
		if !w.StartedAt.IsZero() && (first.IsZero() || w.StartedAt.Before(first)) {
			first = w.StartedAt
		}
	}
	if first.IsZero() {
		first = time.Now()
	}
	return epoch(first)
}

func userName() string {
	if u, err := user.Current(); err == nil {
		n := u.Username
		if i := strings.LastIndexAny(n, `\/`); i >= 0 {
			n = n[i+1:]
		}
		return n
	}
	return "user"
}

func homeDir() string { return paths.Home() }

// --- session and global user options ----------------------------------------

// optStore keeps @options set without -w (session scope) or with -g/-s:
// the pane host only keeps per-window options, so these live in a small
// JSON file in the data dir.
type optStore struct {
	Session map[string]string `json:"session"`
	Global  map[string]string `json:"global"`
}

var optMu sync.Mutex

func optFile() string { return filepath.Join(paths.DataDir(), "tmux-options.json") }

func (r *tmuxRun) optStore() *optStore {
	if r.store == nil {
		r.store = &optStore{Session: map[string]string{}, Global: map[string]string{}}
		optMu.Lock()
		if b, err := os.ReadFile(optFile()); err == nil {
			_ = json.Unmarshal(b, r.store)
		}
		optMu.Unlock()
		if r.store.Session == nil {
			r.store.Session = map[string]string{}
		}
		if r.store.Global == nil {
			r.store.Global = map[string]string{}
		}
	}
	return r.store
}

func (r *tmuxRun) saveStore() error {
	optMu.Lock()
	defer optMu.Unlock()
	b, _ := json.Marshal(r.store)
	_ = os.MkdirAll(filepath.Dir(optFile()), 0o700)
	tmp := optFile() + fmt.Sprintf(".%d.tmp", os.Getpid())
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, optFile())
}

// --- unknown commands, logged once across processes -------------------------

// logUnknown logs a gap the first time it's seen on this machine: a marker
// file per (shim, name) under logs/shim-gaps/.
func logUnknown(shim, name string) {
	safe := strings.Map(func(r rune) rune {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-' || r == '_' {
			return r
		}
		return '_'
	}, name)
	if len(safe) > 64 {
		safe = safe[:64]
	}
	dir := filepath.Join(paths.LogsDir(), "shim-gaps")
	_ = os.MkdirAll(dir, 0o700)
	f, err := os.OpenFile(filepath.Join(dir, shim+"-"+safe), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return // seen before (or the logs dir is unwritable: stay quiet)
	}
	f.Close()
	logx.Printf("%s shim: unsupported %q (first use on this machine)", shim, name)
}
