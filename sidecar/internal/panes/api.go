// Package panes is the pane host: what tmux is to the macOS Sidecar. One
// long-lived process (`bromure-sidecar panehost`) owns a pseudoconsole per
// agent window (ConPTY on Windows, a pty via creack/pty elsewhere), a VT
// screen model with scrollback, window options, and attached clients.
// Agents survive a daemon restart or update because they live here.
//
// The daemon, the tmux and ps shims, `attach` and the hook all talk to it
// through Client, over panes.sock (AF_UNIX, JSON request lines plus binary
// frames for attach streams). Host is the in-process implementation the
// pane host serves; tests may use it directly.
package panes

import (
	"errors"
	"io"
	"time"
)

// SessionName is the one tmux session name clients address ("bromure:3").
const SessionName = "bromure"

// NewWindowRequest starts a window.
type NewWindowRequest struct {
	// Name is the window name (tmux's window_name: the tool, "shell").
	Name string `json:"name"`
	// Argv is the program and its arguments, run directly (no cmd /c). On
	// Windows it is joined with syscall.EscapeArg rules; Cmdline, when set,
	// is passed to CreateProcess verbatim instead (unix: run by /bin/sh -c).
	Argv    []string `json:"argv,omitempty"`
	Cmdline string   `json:"cmdline,omitempty"`
	// Cwd is a real path.
	Cwd string `json:"cwd"`
	// Env is the complete environment ("K=V"); BROMURE_WINDOW,
	// BROMURE_SIDECAR, BROMURE_CONTROL, TMUX_PANE are added by the host.
	Env  []string `json:"env,omitempty"`
	Cols int      `json:"cols,omitempty"` // default 200
	Rows int      `json:"rows,omitempty"` // default 50
	// Options set before the program starts (@display, @bromure_session, …).
	Options map[string]string `json:"options,omitempty"`
	// Hidden windows (a headless sign-in) are left out of List unless asked.
	Hidden bool `json:"hidden,omitempty"`
	// KeepOnExit leaves a dead window listed (with its exit code) instead of
	// closing it when the program exits. Default false: like tmux, the
	// window goes when its program does.
	KeepOnExit bool `json:"keepOnExit,omitempty"`
}

// Window is one window as listed.
type Window struct {
	Index  int    `json:"index"`  // window_index
	ID     string `json:"id"`     // window_id, "@N" (stable, never reused)
	PaneID string `json:"paneId"` // pane_id, "%N"
	Name   string `json:"name"`   // window_name
	// Cwd is the real launch folder (OSC 7 updates it when the program
	// reports one). Virtual paths are the caller's business.
	Cwd string `json:"cwd"`
	// TTY is the fake tty name, "/dev/pty/bromure-<N>" (pane_tty; `ps -t`).
	TTY string `json:"tty"`
	// PID is the root child's pid; StartedAt its start (GetProcessTimes).
	PID       int       `json:"pid"`
	StartedAt time.Time `json:"startedAt"`
	Alive     bool      `json:"alive"`
	ExitCode  *int      `json:"exitCode,omitempty"`
	// Command is pane_current_command: the foreground program's base name
	// without extension ("claude", "bash").
	Command string            `json:"command"`
	Title   string            `json:"title"` // pane_title (OSC 0/2), "" if none
	Active  bool              `json:"active"`
	Width   int               `json:"width"`
	Height  int               `json:"height"`
	Options map[string]string `json:"options"`
	Hidden  bool              `json:"hidden,omitempty"`
	Clients int               `json:"clients"`
}

// CaptureOptions is `capture-pane`'s.
type CaptureOptions struct {
	// Start/End are tmux line numbers: 0 is the first visible line,
	// negative is history. nil = the visible screen's first/last line.
	// StartHistory (`-S -`) starts at the oldest history line.
	Start        *int `json:"start,omitempty"`
	End          *int `json:"end,omitempty"`
	StartHistory bool `json:"startHistory,omitempty"`
	EndVisible   bool `json:"endVisible,omitempty"` // `-E -`
	// Join (-J) joins wrapped lines and keeps trailing spaces.
	Join bool `json:"join,omitempty"`
	// Escapes (-e) includes SGR sequences.
	Escapes bool `json:"escapes,omitempty"`
}

// Screen is the visible screen and its modes.
type Screen struct {
	Text           string `json:"text"` // the visible lines, "\n"-joined
	Width          int    `json:"width"`
	Height         int    `json:"height"`
	CursorX        int    `json:"cursorX"`
	CursorY        int    `json:"cursorY"`
	CursorVisible  bool   `json:"cursorVisible"`
	AltScreen      bool   `json:"altScreen"`
	BracketedPaste bool   `json:"bracketedPaste"` // mode 2004
}

// ClientInfo is one attached client.
type ClientInfo struct {
	ID       string    `json:"id"`
	Window   int       `json:"window"`
	Cols     int       `json:"cols"`
	Rows     int       `json:"rows"`
	Passive  bool      `json:"passive"`
	Activity time.Time `json:"activity"`
	// Flags is tmux's #{client_flags} ("attached,focused,UTF-8" or with
	// "ignore-size" for a passive one).
	Flags string `json:"flags"`
	// TTY is the client's fake tty (client_tty), "/dev/pty/bromure-client-<N>".
	TTY string `json:"tty,omitempty"`
	// Session is the grouped session it was attached for ("view-…"), or "".
	Session string `json:"session,omitempty"`
}

// Proc is one process in a window's tree (the ps shim's source).
type Proc struct {
	PID       int       `json:"pid"`
	PPID      int       `json:"ppid"`
	Window    int       `json:"window"`
	TTY       string    `json:"tty"`
	Args      string    `json:"args"` // the full command line, POSIX-ish
	Exe       string    `json:"exe"`  // base name without extension
	StartedAt time.Time `json:"startedAt"`
	// Foreground marks the window's foreground process: its root child, or
	// the deepest non-shell, non-helper descendant (see the ps shim).
	Foreground bool `json:"foreground"`
}

// Attachment is one client's duplex stream on a window: Read yields the
// initial repaint then live output; Write sends input to the program.
type Attachment interface {
	io.ReadWriteCloser
	// Resize changes this client's size (only a non-passive client's size
	// can win the window's size).
	Resize(cols, rows int) error
	// Exited is closed when the window's program exits; ExitCode is then
	// valid.
	Exited() <-chan struct{}
	ExitCode() int
}

// Client is the pane host's API. Every method is safe for concurrent use.
type Client interface {
	NewWindow(req NewWindowRequest) (Window, error)
	KillWindow(index int) error
	SelectWindow(index int) error
	// List returns the windows by index; hidden ones only when asked.
	List(includeHidden bool) ([]Window, error)
	Get(index int) (Window, error)
	SetOption(index int, key, value string) error
	// UnsetOption removes an option (set-option -u).
	UnsetOption(index int, key string) error
	ShowOption(index int, key string) (string, bool, error)
	Capture(index int, opts CaptureOptions) (string, error)
	Screen(index int) (Screen, error)
	// SendKeys: tmux key names (Enter, Escape, Up, C-c, BSpace, Tab, M-x,
	// F1…) → VT sequences; literal sends each string as text.
	SendKeys(index int, keys []string, literal bool) error
	// Paste writes text as one paste: wrapped in ESC[200~ … ESC[201~ only
	// when bracketed is true AND the program turned mode 2004 on (tmux's
	// paste-buffer -p). LF is sent as CR unless raw (paste-buffer -r).
	Paste(index int, text string, bracketed, raw bool) error
	Attach(index int, cols, rows int, passive bool) (Attachment, error)
	ResizeWindow(index int, cols, rows int) error
	ListClients() ([]ClientInfo, error)
	ProcTable() ([]Proc, error)
	// Buffers (load-buffer / paste-buffer -b / delete-buffer), kept by the
	// host so separate shim processes can stage and paste.
	SetBuffer(name string, data []byte) error
	PasteBuffer(name string, index int, bracketed, raw, del bool) error
	DeleteBuffer(name string) error
	Close() error
	// AttachWith, RefreshClient, DetachSession (added; see ClientControl).
	ClientControl
}

// HostVersion is the pane host protocol version; the daemon restarts an
// older pane host only when it has no windows.
const HostVersion = 1

// --- Additions (beyond the first draft of this file) ---

// Errors the host returns; they survive the socket (errors.Is works on a
// remote Client's errors too).
var (
	ErrNoWindow = errors.New("can't find window")
	ErrNoBuffer = errors.New("no buffer")
	ErrNoClient = errors.New("can't find client")
	ErrExited   = errors.New("window's program has exited")
)

// AttachRequest is Attach with the grouped tmux session the client stands
// for ("view-<name>", what `list-clients -t` / `kill-session -t` address).
type AttachRequest struct {
	Index   int    `json:"index"`
	Cols    int    `json:"cols"`
	Rows    int    `json:"rows"`
	Passive bool   `json:"passive,omitempty"`
	Session string `json:"session,omitempty"`
}

// ClientControl is what the tmux shim needs beyond Client for
// `refresh-client` and `kill-session -t view-*`. Host and the socket
// client both implement it.
type ClientControl interface {
	AttachWith(req AttachRequest) (Attachment, error)
	// RefreshClient: `refresh-client -t <client> [-f [!]ignore-size]
	// [-C WxH]`. id is a ClientInfo.ID or .TTY; passive nil leaves the flag,
	// cols/rows 0 leave the size. Sizes are then recalculated.
	RefreshClient(id string, passive *bool, cols, rows int) error
	// DetachSession detaches every client of a grouped session; how many.
	DetachSession(session string) (int, error)
}
