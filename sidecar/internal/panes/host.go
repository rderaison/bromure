package panes

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/paths"
	"github.com/rderaison/bromure/sidecar/internal/pty"
)

// DefaultHistory is each window's scrollback, in lines.
const DefaultHistory = 10000

const (
	defaultCols = 200
	defaultRows = 50
	// maxClientQueue: a client this far behind is resynchronised with a
	// fresh repaint instead of buffering more.
	maxClientQueue = 8 << 20
	maxInputQueue  = 32 << 20
)

// Host is the in-process pane host (what `bromure-sidecar panehost`
// serves). The zero value is not usable; use NewHost.
type Host struct {
	mu       sync.Mutex
	windows  map[int]*window
	nextWin  int
	nextPane int
	nextCli  int
	active   int
	buffers  map[string][]byte
	bufOrder []string
	histMax  int
	closed   bool
}

var _ Client = (*Host)(nil)

// NewHost makes an empty pane host.
func NewHost() *Host {
	return &Host{windows: map[int]*window{}, active: -1, buffers: map[string][]byte{}, histMax: DefaultHistory}
}

type window struct {
	h          *Host
	index      int
	id, pane   int
	name       string
	launchCwd  string
	argv0      string
	hidden     bool
	keepOnExit bool
	proc       *pty.Process
	pumpDone   chan struct{}
	exited     chan struct{}

	in *inputQueue

	mu       sync.Mutex // everything below (lock order: Host.mu, then this)
	t        *term
	options  map[string]string
	clients  []*client
	cols     int
	rows     int
	manual   bool // resize-window: clients no longer size it
	alive    bool
	exitCode int
	killed   bool
}

func (h *Host) lookup(index int) (*window, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	w := h.windows[index]
	if w == nil {
		return nil, fmt.Errorf("%w: %d", ErrNoWindow, index)
	}
	return w, nil
}

// NewWindow starts a program in a new window at the lowest free index.
func (h *Host) NewWindow(req NewWindowRequest) (Window, error) {
	cols, rows := req.Cols, req.Rows
	if cols <= 0 {
		cols = defaultCols
	}
	if rows <= 0 {
		rows = defaultRows
	}
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return Window{}, fmt.Errorf("pane host is shutting down")
	}
	idx := 0
	for h.windows[idx] != nil {
		idx++
	}
	pane := h.nextPane
	env := windowEnv(req.Env, idx, pane)
	proc, err := pty.Start(pty.Spec{Argv: req.Argv, Cmdline: req.Cmdline, Env: env, Dir: req.Cwd, Cols: cols, Rows: rows})
	if err != nil {
		h.mu.Unlock()
		return Window{}, err
	}
	w := &window{
		h: h, index: idx, id: h.nextWin, pane: pane, name: req.Name, launchCwd: req.Cwd,
		hidden: req.Hidden, keepOnExit: req.KeepOnExit, proc: proc,
		pumpDone: make(chan struct{}), exited: make(chan struct{}),
		t: newTerm(cols, rows, h.histMax), options: map[string]string{},
		cols: cols, rows: rows, alive: true,
	}
	if len(req.Argv) > 0 {
		w.argv0 = req.Argv[0]
	} else {
		w.argv0 = firstWord(req.Cmdline)
	}
	if w.name == "" {
		w.name = exeBase(w.argv0)
	}
	for k, v := range req.Options {
		w.options[k] = v
	}
	w.in = newInputQueue(proc)
	h.nextWin++
	h.nextPane++
	h.windows[idx] = w
	if h.active < 0 || h.windows[h.active] == nil {
		h.active = idx
	}
	go w.pump()
	go w.waiter()
	desc := h.describeLocked(w, nil)
	h.mu.Unlock()
	logx.Printf("panes: window %d (@%d %%%d) started pid %d: %s", idx, w.id, w.pane, proc.Pid(), w.name)
	return desc, nil
}

// windowEnv is req.Env plus what every window gets.
func windowEnv(env []string, idx, pane int) []string {
	if env == nil {
		env = os.Environ()
	}
	fold := runtime.GOOS == "windows"
	sidecar := ""
	hasTerm := false
	out := make([]string, 0, len(env)+5)
	for _, kv := range env {
		k, v, ok := strings.Cut(kv, "=")
		if !ok {
			continue
		}
		key := k
		if fold {
			key = strings.ToUpper(k)
		}
		switch key {
		case "BROMURE_WINDOW", "TMUX_PANE", "BROMURE_CONTROL", "TMUX":
			continue
		case "BROMURE_SIDECAR":
			sidecar = v
			continue
		case "TERM":
			hasTerm = true
		}
		out = append(out, kv)
	}
	if sidecar == "" {
		sidecar = paths.Executable()
	}
	out = append(out,
		fmt.Sprintf("BROMURE_WINDOW=%d", idx),
		fmt.Sprintf("TMUX_PANE=%%%d", pane),
		"BROMURE_CONTROL="+paths.ControlSocket(),
		"BROMURE_SIDECAR="+sidecar,
	)
	if !hasTerm && runtime.GOOS != "windows" {
		out = append(out, "TERM=xterm-256color")
	}
	return out
}

func (w *window) pump() {
	defer close(w.pumpDone)
	buf := make([]byte, 64*1024)
	for {
		n, err := w.proc.Read(buf)
		if n > 0 {
			w.mu.Lock()
			w.t.write(buf[:n])
			out := w.t.takeOutput()
			rep := w.t.takeReplies()
			if len(out) > 0 {
				for _, c := range w.clients {
					if !c.q.push(out) {
						c.q.reset(w.t.repaint())
					}
				}
			}
			w.mu.Unlock()
			if len(rep) > 0 {
				w.in.push(rep)
			}
		}
		if err != nil {
			return
		}
	}
}

// exitGrace is how long output may keep draining after the program exits
// before the console is shut (a ConPTY never reaches EOF on its own).
var exitGrace = func() time.Duration {
	if runtime.GOOS == "windows" {
		return 150 * time.Millisecond
	}
	return 300 * time.Millisecond
}()

func (w *window) waiter() {
	code := w.proc.Wait()
	select {
	case <-w.pumpDone:
	case <-time.After(exitGrace):
	}
	w.proc.Close()
	select {
	case <-w.pumpDone:
	case <-time.After(5 * time.Second):
	}
	w.in.close()
	h := w.h
	h.mu.Lock()
	w.mu.Lock()
	w.alive = false
	w.exitCode = code
	clients := w.clients
	w.clients = nil
	remove := !w.keepOnExit || w.killed
	if remove && h.windows[w.index] == w {
		delete(h.windows, w.index)
		h.fixActiveLocked()
	}
	w.mu.Unlock()
	close(w.exited)
	h.mu.Unlock()
	for _, c := range clients {
		c.q.close()
	}
	logx.Printf("panes: window %d (@%d) exited with %d", w.index, w.id, code)
}

func (h *Host) fixActiveLocked() {
	if h.windows[h.active] != nil {
		return
	}
	h.active = -1
	best := -1
	for i := range h.windows {
		if best < 0 || i < best {
			best = i
		}
	}
	h.active = best
}

// KillWindow kills a window's whole process tree and removes it.
func (h *Host) KillWindow(index int) error {
	h.mu.Lock()
	w := h.windows[index]
	if w == nil {
		h.mu.Unlock()
		return fmt.Errorf("%w: %d", ErrNoWindow, index)
	}
	delete(h.windows, index)
	h.fixActiveLocked()
	h.mu.Unlock()
	w.mu.Lock()
	w.killed = true
	w.mu.Unlock()
	w.proc.Kill()
	w.proc.Close()
	logx.Printf("panes: window %d (@%d) killed", index, w.id)
	return nil
}

// SelectWindow makes a window the active one.
func (h *Host) SelectWindow(index int) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.windows[index] == nil {
		return fmt.Errorf("%w: %d", ErrNoWindow, index)
	}
	h.active = index
	return nil
}

// List returns the windows by index.
func (h *Host) List(includeHidden bool) ([]Window, error) {
	procs := h.procTableFor(nil)
	h.mu.Lock()
	defer h.mu.Unlock()
	idx := make([]int, 0, len(h.windows))
	for i, w := range h.windows {
		if w.hidden && !includeHidden {
			continue
		}
		idx = append(idx, i)
	}
	sort.Ints(idx)
	out := make([]Window, 0, len(idx))
	for _, i := range idx {
		out = append(out, h.describeLocked(h.windows[i], procs))
	}
	return out, nil
}

// Get returns one window (hidden or not).
func (h *Host) Get(index int) (Window, error) {
	w, err := h.lookup(index)
	if err != nil {
		return Window{}, err
	}
	procs := h.procTableFor([]*window{w})
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.windows[index] != w {
		return Window{}, fmt.Errorf("%w: %d", ErrNoWindow, index)
	}
	return h.describeLocked(w, procs), nil
}

func (h *Host) describeLocked(w *window, procs []Proc) Window {
	w.mu.Lock()
	defer w.mu.Unlock()
	d := Window{
		Index: w.index, ID: fmt.Sprintf("@%d", w.id), PaneID: fmt.Sprintf("%%%d", w.pane),
		Name: w.name, Cwd: w.launchCwd, TTY: w.tty(), PID: w.proc.Pid(), StartedAt: w.proc.StartedAt(),
		Alive: w.alive, Title: w.t.title, Active: h.active == w.index,
		Width: w.cols, Height: w.rows, Hidden: w.hidden, Clients: len(w.clients),
		Options: make(map[string]string, len(w.options)),
	}
	if w.t.cwd != "" {
		d.Cwd = w.t.cwd
	}
	if !w.alive {
		c := w.exitCode
		d.ExitCode = &c
	}
	for k, v := range w.options {
		d.Options[k] = v
	}
	d.Command = exeBase(w.argv0)
	for _, p := range procs {
		if p.Window == w.index && p.Foreground && p.TTY == d.TTY {
			d.Command = p.Exe
			break
		}
	}
	return d
}

func (w *window) tty() string { return fmt.Sprintf("/dev/pty/bromure-%d", w.pane) }

// SetOption sets a window option. "window-size" is tmux's: "manual" pins
// the size, anything else hands it back to the clients.
func (h *Host) SetOption(index int, key, value string) error {
	w, err := h.lookup(index)
	if err != nil {
		return err
	}
	if key == "window-size" {
		w.mu.Lock()
		w.manual = value == "manual"
		w.mu.Unlock()
		w.recomputeSize()
		return nil
	}
	w.mu.Lock()
	w.options[key] = value
	w.mu.Unlock()
	return nil
}

// UnsetOption removes an option (unsetting "window-size" ends a manual size).
func (h *Host) UnsetOption(index int, key string) error {
	w, err := h.lookup(index)
	if err != nil {
		return err
	}
	if key == "window-size" {
		w.mu.Lock()
		w.manual = false
		w.mu.Unlock()
		w.recomputeSize()
		return nil
	}
	w.mu.Lock()
	delete(w.options, key)
	w.mu.Unlock()
	return nil
}

// ShowOption reads an option.
func (h *Host) ShowOption(index int, key string) (string, bool, error) {
	w, err := h.lookup(index)
	if err != nil {
		return "", false, err
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if key == "window-size" {
		if w.manual {
			return "manual", true, nil
		}
		return "", false, nil
	}
	v, ok := w.options[key]
	return v, ok, nil
}

// Capture is capture-pane.
func (h *Host) Capture(index int, opts CaptureOptions) (string, error) {
	w, err := h.lookup(index)
	if err != nil {
		return "", err
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.t.capture(opts), nil
}

// Screen is the visible screen and its modes.
func (h *Host) Screen(index int) (Screen, error) {
	w, err := h.lookup(index)
	if err != nil {
		return Screen{}, err
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	t := w.t
	return Screen{
		Text: t.screenText(), Width: t.cols, Height: t.rows, CursorX: t.cx, CursorY: t.cy,
		CursorVisible: t.cursorVisible, AltScreen: t.alt, BracketedPaste: t.bracketed,
	}, nil
}

// SendKeys is send-keys.
func (h *Host) SendKeys(index int, keys []string, literal bool) error {
	w, err := h.lookup(index)
	if err != nil {
		return err
	}
	w.mu.Lock()
	ck := w.t.cursorKeys
	alive := w.alive
	w.mu.Unlock()
	if !alive {
		return ErrExited
	}
	var b strings.Builder
	for _, k := range keys {
		if literal {
			b.WriteString(k)
		} else {
			b.WriteString(translateKey(k, ck))
		}
	}
	return w.in.push([]byte(b.String()))
}

// Paste is paste-buffer: LF becomes CR unless raw; wrapped in bracketed
// paste markers only when asked and the program turned mode 2004 on.
func (h *Host) Paste(index int, text string, bracketed, raw bool) error {
	w, err := h.lookup(index)
	if err != nil {
		return err
	}
	w.mu.Lock()
	on := w.t.bracketed
	alive := w.alive
	w.mu.Unlock()
	if !alive {
		return ErrExited
	}
	if !raw {
		text = strings.ReplaceAll(text, "\n", "\r")
	}
	if bracketed && on {
		text = "\x1b[200~" + text + "\x1b[201~"
	}
	return w.in.push([]byte(text))
}

// ResizeWindow is resize-window -x -y: the size is then manual (clients
// stop sizing it) until the window-size option is unset.
func (h *Host) ResizeWindow(index int, cols, rows int) error {
	w, err := h.lookup(index)
	if err != nil {
		return err
	}
	w.mu.Lock()
	w.manual = true
	if cols <= 0 {
		cols = w.cols
	}
	if rows <= 0 {
		rows = w.rows
	}
	w.setSizeLocked(cols, rows)
	w.mu.Unlock()
	return nil
}

func (w *window) setSizeLocked(cols, rows int) {
	if cols < 1 {
		cols = 1
	}
	if rows < 1 {
		rows = 1
	}
	if cols > 10000 {
		cols = 10000
	}
	if rows > 10000 {
		rows = 10000
	}
	if cols == w.cols && rows == w.rows {
		return
	}
	w.cols, w.rows = cols, rows
	w.t.resize(cols, rows)
	if w.alive {
		w.proc.Resize(cols, rows)
	}
}

// recomputeSize applies tmux 3.4's window-size "latest": the non-passive
// client with the latest activity sizes the window. Passive clients never
// do; with none, the window keeps its size.
func (w *window) recomputeSize() {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.manual {
		return
	}
	var best *client
	for _, c := range w.clients {
		if c.passive {
			continue
		}
		if best == nil || !c.activity.Before(best.activity) {
			best = c
		}
	}
	if best != nil {
		w.setSizeLocked(best.cols, best.rows)
	}
}

// --- buffers ---

// SetBuffer is load-buffer -b name.
func (h *Host) SetBuffer(name string, data []byte) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	if name == "" {
		name = fmt.Sprintf("buffer%d", len(h.bufOrder))
	}
	h.buffers[name] = append([]byte(nil), data...)
	h.touchBufferLocked(name)
	return nil
}

func (h *Host) touchBufferLocked(name string) {
	for i, n := range h.bufOrder {
		if n == name {
			h.bufOrder = append(h.bufOrder[:i], h.bufOrder[i+1:]...)
			break
		}
	}
	h.bufOrder = append(h.bufOrder, name)
}

// PasteBuffer is paste-buffer [-b name] (the most recent buffer when name
// is ""), -d deleting it after.
func (h *Host) PasteBuffer(name string, index int, bracketed, raw, del bool) error {
	h.mu.Lock()
	if name == "" && len(h.bufOrder) > 0 {
		name = h.bufOrder[len(h.bufOrder)-1]
	}
	data, ok := h.buffers[name]
	h.mu.Unlock()
	if !ok {
		return fmt.Errorf("%w %s", ErrNoBuffer, name)
	}
	if err := h.Paste(index, string(data), bracketed, raw); err != nil {
		return err
	}
	if del {
		return h.DeleteBuffer(name)
	}
	return nil
}

// DeleteBuffer is delete-buffer -b name.
func (h *Host) DeleteBuffer(name string) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	if name == "" && len(h.bufOrder) > 0 {
		name = h.bufOrder[len(h.bufOrder)-1]
	}
	if _, ok := h.buffers[name]; !ok {
		return fmt.Errorf("%w %s", ErrNoBuffer, name)
	}
	delete(h.buffers, name)
	for i, n := range h.bufOrder {
		if n == name {
			h.bufOrder = append(h.bufOrder[:i], h.bufOrder[i+1:]...)
			break
		}
	}
	return nil
}

// WindowCount is how many windows exist (hidden and dead-kept included).
func (h *Host) WindowCount() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.windows)
}

// Close kills every window.
func (h *Host) Close() error {
	h.mu.Lock()
	h.closed = true
	var idx []int
	for i := range h.windows {
		idx = append(idx, i)
	}
	h.mu.Unlock()
	for _, i := range idx {
		h.KillWindow(i)
	}
	return nil
}

// --- clients ---

type client struct {
	id       int
	w        *window
	cols     int
	rows     int
	passive  bool
	session  string
	activity time.Time
	q        *outQueue
	closed   bool
}

// Attach attaches a client to a window.
func (h *Host) Attach(index int, cols, rows int, passive bool) (Attachment, error) {
	return h.AttachWith(AttachRequest{Index: index, Cols: cols, Rows: rows, Passive: passive})
}

// AttachWith attaches a client: it gets a full repaint, then live output.
func (h *Host) AttachWith(req AttachRequest) (Attachment, error) {
	h.mu.Lock()
	w := h.windows[req.Index]
	if w == nil {
		h.mu.Unlock()
		return nil, fmt.Errorf("%w: %d", ErrNoWindow, req.Index)
	}
	id := h.nextCli
	h.nextCli++
	h.mu.Unlock()
	c := &client{id: id, w: w, cols: req.Cols, rows: req.Rows, passive: req.Passive,
		session: req.Session, activity: time.Now(), q: newOutQueue()}
	if c.cols <= 0 || c.rows <= 0 {
		c.passive = c.passive || c.cols <= 0 || c.rows <= 0
	}
	w.mu.Lock()
	c.q.push(w.t.repaint())
	if !w.alive {
		w.mu.Unlock()
		c.q.close()
		return &localAttachment{c: c}, nil
	}
	w.clients = append(w.clients, c)
	w.mu.Unlock()
	w.recomputeSize()
	return &localAttachment{c: c}, nil
}

func (c *client) info() ClientInfo {
	flags := "attached,focused,UTF-8"
	if c.passive {
		flags = "attached,focused,ignore-size,UTF-8"
	}
	return ClientInfo{
		ID: fmt.Sprintf("client-%d", c.id), TTY: fmt.Sprintf("/dev/pty/bromure-client-%d", c.id),
		Window: c.w.index, Cols: c.cols, Rows: c.rows, Passive: c.passive, Activity: c.activity,
		Flags: flags, Session: c.session,
	}
}

// ListClients lists attached clients by window, then age.
func (h *Host) ListClients() ([]ClientInfo, error) {
	h.mu.Lock()
	ws := make([]*window, 0, len(h.windows))
	for _, w := range h.windows {
		ws = append(ws, w)
	}
	h.mu.Unlock()
	var out []ClientInfo
	for _, w := range ws {
		w.mu.Lock()
		for _, c := range w.clients {
			out = append(out, c.info())
		}
		w.mu.Unlock()
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Window != out[j].Window {
			return out[i].Window < out[j].Window
		}
		return out[i].ID < out[j].ID
	})
	return out, nil
}

func (h *Host) findClient(id string) *client {
	h.mu.Lock()
	ws := make([]*window, 0, len(h.windows))
	for _, w := range h.windows {
		ws = append(ws, w)
	}
	h.mu.Unlock()
	for _, w := range ws {
		w.mu.Lock()
		for _, c := range w.clients {
			ci := c.info()
			if ci.ID == id || ci.TTY == id {
				w.mu.Unlock()
				return c
			}
		}
		w.mu.Unlock()
	}
	return nil
}

// RefreshClient changes a client's ignore-size flag and/or size.
func (h *Host) RefreshClient(id string, passive *bool, cols, rows int) error {
	c := h.findClient(id)
	if c == nil {
		return fmt.Errorf("%w: %s", ErrNoClient, id)
	}
	w := c.w
	w.mu.Lock()
	if passive != nil {
		c.passive = *passive
	}
	if cols > 0 && rows > 0 {
		c.cols, c.rows = cols, rows
	}
	w.mu.Unlock()
	w.recomputeSize()
	return nil
}

// DetachSession detaches the clients attached for a grouped session.
func (h *Host) DetachSession(session string) (int, error) {
	h.mu.Lock()
	ws := make([]*window, 0, len(h.windows))
	for _, w := range h.windows {
		ws = append(ws, w)
	}
	h.mu.Unlock()
	n := 0
	for _, w := range ws {
		w.mu.Lock()
		var gone []*client
		keep := w.clients[:0]
		for _, c := range w.clients {
			if c.session == session && session != "" {
				gone = append(gone, c)
				c.closed = true
			} else {
				keep = append(keep, c)
			}
		}
		w.clients = keep
		w.mu.Unlock()
		for _, c := range gone {
			c.q.close()
			n++
		}
		if len(gone) > 0 {
			w.recomputeSize()
		}
	}
	return n, nil
}

type localAttachment struct {
	c    *client
	once sync.Once
}

func (a *localAttachment) Read(p []byte) (int, error) { return a.c.q.read(p) }

func (a *localAttachment) Write(p []byte) (int, error) {
	w := a.c.w
	w.mu.Lock()
	if a.c.closed || !w.alive {
		w.mu.Unlock()
		return 0, ErrExited
	}
	a.c.activity = time.Now()
	w.mu.Unlock()
	w.recomputeSize()
	if err := w.in.push(p); err != nil {
		return 0, err
	}
	return len(p), nil
}

func (a *localAttachment) Resize(cols, rows int) error {
	w := a.c.w
	w.mu.Lock()
	if cols > 0 && rows > 0 {
		a.c.cols, a.c.rows = cols, rows
	}
	a.c.activity = time.Now()
	w.mu.Unlock()
	w.recomputeSize()
	return nil
}

func (a *localAttachment) Exited() <-chan struct{} { return a.c.w.exited }

func (a *localAttachment) ExitCode() int {
	w := a.c.w
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.exitCode
}

func (a *localAttachment) Close() error {
	a.once.Do(func() {
		w := a.c.w
		w.mu.Lock()
		a.c.closed = true
		for i, c := range w.clients {
			if c == a.c {
				w.clients = append(w.clients[:i], w.clients[i+1:]...)
				break
			}
		}
		w.mu.Unlock()
		a.c.q.close()
		w.recomputeSize()
	})
	return nil
}

// outQueue is one client's pending output.
type outQueue struct {
	mu     sync.Mutex
	cond   *sync.Cond
	buf    []byte
	closed bool
}

func newOutQueue() *outQueue {
	q := &outQueue{}
	q.cond = sync.NewCond(&q.mu)
	return q
}

// push queues b; false when the client is too far behind (the caller then
// resets it with a repaint).
func (q *outQueue) push(b []byte) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.closed {
		return true
	}
	if len(q.buf)+len(b) > maxClientQueue {
		return false
	}
	q.buf = append(q.buf, b...)
	q.cond.Broadcast()
	return true
}

func (q *outQueue) reset(b []byte) {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.buf = append([]byte("\x1bc"), b...)
	q.cond.Broadcast()
}

func (q *outQueue) close() {
	q.mu.Lock()
	q.closed = true
	q.cond.Broadcast()
	q.mu.Unlock()
}

func (q *outQueue) read(p []byte) (int, error) {
	q.mu.Lock()
	defer q.mu.Unlock()
	for len(q.buf) == 0 && !q.closed {
		q.cond.Wait()
	}
	if len(q.buf) == 0 {
		return 0, io.EOF
	}
	n := copy(p, q.buf)
	q.buf = q.buf[n:]
	if len(q.buf) == 0 {
		q.buf = nil
	}
	return n, nil
}

// inputQueue serialises everything written to a window's program (keys,
// pastes, clients, terminal replies) on one goroutine, so no caller blocks
// on a program that isn't reading its input.
type inputQueue struct {
	mu     sync.Mutex
	cond   *sync.Cond
	buf    []byte
	closed bool
	w      io.Writer
}

func newInputQueue(w io.Writer) *inputQueue {
	q := &inputQueue{w: w}
	q.cond = sync.NewCond(&q.mu)
	go q.run()
	return q
}

func (q *inputQueue) push(b []byte) error {
	if len(b) == 0 {
		return nil
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.closed {
		return ErrExited
	}
	if len(q.buf)+len(b) > maxInputQueue {
		return fmt.Errorf("panes: the program isn't reading its input")
	}
	q.buf = append(q.buf, b...)
	q.cond.Broadcast()
	return nil
}

func (q *inputQueue) close() {
	q.mu.Lock()
	q.closed = true
	q.buf = nil
	q.cond.Broadcast()
	q.mu.Unlock()
}

func (q *inputQueue) run() {
	for {
		q.mu.Lock()
		for len(q.buf) == 0 && !q.closed {
			q.cond.Wait()
		}
		if q.closed {
			q.mu.Unlock()
			return
		}
		b := q.buf
		q.buf = nil
		q.mu.Unlock()
		// Large writes in chunks: a ConPTY input pipe takes 4 KB at a time
		// and conhost parses as it reads.
		for len(b) > 0 {
			n := len(b)
			if n > 16*1024 {
				n = 16 * 1024
			}
			if _, err := q.w.Write(b[:n]); err != nil {
				q.close()
				return
			}
			b = b[n:]
		}
	}
}

// exeBase is a program's base name without directory or extension.
func exeBase(p string) string {
	p = strings.Trim(p, `"`)
	if i := strings.LastIndexAny(p, `/\`); i >= 0 {
		p = p[i+1:]
	}
	if ext := filepath.Ext(p); ext != "" {
		switch strings.ToLower(ext) {
		case ".exe", ".cmd", ".bat", ".com":
			p = p[:len(p)-len(ext)]
		}
	}
	return strings.TrimPrefix(p, "-")
}

// firstWord is a command line's program (Windows quoting).
func firstWord(cmdline string) string {
	s := strings.TrimLeft(cmdline, " \t")
	if strings.HasPrefix(s, `"`) {
		if i := strings.IndexByte(s[1:], '"'); i >= 0 {
			return s[1 : i+1]
		}
		return s[1:]
	}
	if i := strings.IndexAny(s, " \t"); i >= 0 {
		return s[:i]
	}
	return s
}
