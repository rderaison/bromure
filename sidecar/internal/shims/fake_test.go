package shims

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/panes"
	"github.com/rderaison/bromure/sidecar/internal/paths"
	"github.com/rderaison/bromure/sidecar/internal/vpath"
)

// fakeClient is an in-memory pane host.
type fakeClient struct {
	mu       sync.Mutex
	wins     map[int]*panes.Window
	screens  map[int]panes.Screen
	captures map[int]string
	buffers  map[string][]byte
	clients  []panes.ClientInfo
	procs    []panes.Proc
	nextID   int

	keys      []string // "idx:literal|keys:a,b"
	pastes    []string
	captured  []panes.CaptureOptions
	resized   []string
	refreshed []string
	detached  []string
	selected  []int
	killed    []int
}

func newFake() *fakeClient {
	return &fakeClient{wins: map[int]*panes.Window{}, screens: map[int]panes.Screen{},
		captures: map[int]string{}, buffers: map[string][]byte{}, nextID: 10}
}

func (f *fakeClient) add(w panes.Window) {
	if w.Options == nil {
		w.Options = map[string]string{}
	}
	f.wins[w.Index] = &w
}

func (f *fakeClient) get(i int) (*panes.Window, error) {
	w, ok := f.wins[i]
	if !ok {
		return nil, fmt.Errorf("no window %d", i)
	}
	return w, nil
}

func (f *fakeClient) NewWindow(req panes.NewWindowRequest) (panes.Window, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	idx := 0
	for f.wins[idx] != nil {
		idx++
	}
	n := f.nextID
	f.nextID++
	w := panes.Window{Index: idx, ID: fmt.Sprintf("@%d", n), PaneID: fmt.Sprintf("%%%d", n), Name: req.Name,
		Cwd: req.Cwd, TTY: fmt.Sprintf("/dev/pty/bromure-%d", n), PID: 9000 + n, Alive: true,
		Command: "bash", Width: 200, Height: 50, Options: map[string]string{}}
	for k, v := range req.Options {
		w.Options[k] = v
	}
	f.wins[idx] = &w
	return w, nil
}

func (f *fakeClient) KillWindow(i int) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if _, err := f.get(i); err != nil {
		return err
	}
	delete(f.wins, i)
	f.killed = append(f.killed, i)
	return nil
}

func (f *fakeClient) SelectWindow(i int) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if _, err := f.get(i); err != nil {
		return err
	}
	for k, w := range f.wins {
		w.Active = k == i
	}
	f.selected = append(f.selected, i)
	return nil
}

func (f *fakeClient) List(includeHidden bool) ([]panes.Window, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []panes.Window
	for _, w := range f.wins {
		if w.Hidden && !includeHidden {
			continue
		}
		c := *w
		c.Options = map[string]string{}
		for k, v := range w.Options {
			c.Options[k] = v
		}
		out = append(out, c)
	}
	sort.Slice(out, func(a, b int) bool { return out[a].Index < out[b].Index })
	return out, nil
}

func (f *fakeClient) Get(i int) (panes.Window, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	w, err := f.get(i)
	if err != nil {
		return panes.Window{}, err
	}
	return *w, nil
}

func (f *fakeClient) SetOption(i int, k, v string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	w, err := f.get(i)
	if err != nil {
		return err
	}
	w.Options[k] = v
	return nil
}

func (f *fakeClient) UnsetOption(i int, k string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	w, err := f.get(i)
	if err != nil {
		return err
	}
	delete(w.Options, k)
	return nil
}

func (f *fakeClient) ShowOption(i int, k string) (string, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	w, err := f.get(i)
	if err != nil {
		return "", false, err
	}
	v, ok := w.Options[k]
	return v, ok, nil
}

func (f *fakeClient) Capture(i int, o panes.CaptureOptions) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if _, err := f.get(i); err != nil {
		return "", err
	}
	f.captured = append(f.captured, o)
	return f.captures[i], nil
}

func (f *fakeClient) Screen(i int) (panes.Screen, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if _, err := f.get(i); err != nil {
		return panes.Screen{}, err
	}
	return f.screens[i], nil
}

func (f *fakeClient) SendKeys(i int, keys []string, literal bool) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if _, err := f.get(i); err != nil {
		return err
	}
	kind := "keys"
	if literal {
		kind = "literal"
	}
	f.keys = append(f.keys, fmt.Sprintf("%d:%s:%s", i, kind, strings.Join(keys, ",")))
	return nil
}

func (f *fakeClient) Paste(i int, text string, bracketed, raw bool) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.pastes = append(f.pastes, fmt.Sprintf("%d:%v:%v:%s", i, bracketed, raw, text))
	return nil
}

func (f *fakeClient) Attach(int, int, int, bool) (panes.Attachment, error) {
	return nil, errors.New("not in tests")
}

func (f *fakeClient) ResizeWindow(i, cols, rows int) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	w, err := f.get(i)
	if err != nil {
		return err
	}
	w.Width, w.Height = cols, rows
	f.resized = append(f.resized, fmt.Sprintf("%d:%dx%d", i, cols, rows))
	return nil
}

func (f *fakeClient) ListClients() ([]panes.ClientInfo, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]panes.ClientInfo(nil), f.clients...), nil
}

func (f *fakeClient) ProcTable() ([]panes.Proc, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]panes.Proc(nil), f.procs...), nil
}

func (f *fakeClient) SetBuffer(name string, data []byte) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.buffers[name] = append([]byte(nil), data...)
	return nil
}

func (f *fakeClient) PasteBuffer(name string, i int, bracketed, raw, del bool) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if _, err := f.get(i); err != nil {
		return err
	}
	b, ok := f.buffers[name]
	if !ok {
		return fmt.Errorf("no buffer %s", name)
	}
	f.pastes = append(f.pastes, fmt.Sprintf("%d:%v:%v:%s", i, bracketed, raw, b))
	if del {
		delete(f.buffers, name)
	}
	return nil
}

func (f *fakeClient) DeleteBuffer(name string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if _, ok := f.buffers[name]; !ok {
		return fmt.Errorf("unknown buffer: %s", name)
	}
	delete(f.buffers, name)
	return nil
}

func (f *fakeClient) Close() error { return nil }

func (f *fakeClient) AttachWith(panes.AttachRequest) (panes.Attachment, error) {
	return nil, errors.New("not in tests")
}

func (f *fakeClient) RefreshClient(id string, passive *bool, cols, rows int) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	p := "-"
	if passive != nil {
		p = fmt.Sprint(*passive)
	}
	f.refreshed = append(f.refreshed, fmt.Sprintf("%s:%s:%dx%d", id, p, cols, rows))
	return nil
}

func (f *fakeClient) DetachSession(s string) (int, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.detached = append(f.detached, s)
	return 1, nil
}

var _ panes.Client = (*fakeClient)(nil)

// standardFake is two agent windows and a shell, as a live session looks.
func standardFake(t *testing.T) *fakeClient {
	t.Helper()
	// One data dir for the test binary (logx keeps its log open, which a
	// per-test TempDir can't remove on Windows); a fresh option store.
	os.Remove(filepath.Join(paths.DataDir(), "tmux-options.json"))
	vpath.SetDefaultForTest(&vpath.Mapper{Home: "/home/me", Temp: "/tmp", Windows: false})
	f := newFake()
	start := time.Now().Add(-90 * time.Second)
	f.add(panes.Window{Index: 0, ID: "@0", PaneID: "%0", Name: "shell", Cwd: "/home/me", TTY: "/dev/pty/bromure-0",
		PID: 100, StartedAt: start, Alive: true, Command: "bash", Width: 120, Height: 40, Active: true})
	f.add(panes.Window{Index: 1, ID: "@1", PaneID: "%1", Name: "claude", Cwd: "/home/me/src/proj", TTY: "/dev/pty/bromure-1",
		PID: 200, StartedAt: start, Alive: true, Command: "claude", Title: "✳ Fix the bug", Width: 120, Height: 40,
		Options: map[string]string{"@worktree": "wt/fix-bug", "@display": "Fix the bug"}})
	f.add(panes.Window{Index: 3, ID: "@3", PaneID: "%3", Name: "codex", Cwd: "/home/me/src/other", TTY: "/dev/pty/bromure-3",
		PID: 300, StartedAt: start, Alive: true, Command: "node", Width: 100, Height: 30,
		Options: map[string]string{"@worktree": "wt/other"}})
	f.screens[1] = panes.Screen{Width: 120, Height: 40, CursorX: 4, CursorY: 37, CursorVisible: true}
	f.captures[1] = "line one\n> draft\n" // the pane host ends every line
	f.clients = []panes.ClientInfo{
		{ID: "c1", TTY: "/dev/pty/bromure-client-1", Session: "view-mac-1", Window: 1, Cols: 120, Rows: 40, Flags: "attached,focused,UTF-8"},
		{ID: "c2", TTY: "/dev/pty/bromure-client-2", Session: "view-mac-3", Window: 3, Cols: 80, Rows: 24, Passive: true, Flags: "attached,ignore-size,UTF-8"},
	}
	return f
}

// tmuxOut runs the shim and returns stdout, stderr, status.
func tmuxOut(f panes.Client, env map[string]string, stdin string, args ...string) (string, string, int) {
	var out, errb bytes.Buffer
	r := &tmuxRun{c: f, stdin: strings.NewReader(stdin), stdout: &out, stderr: &errb, socket: "default",
		getenv: func(k string) string {
			if env != nil {
				return env[k]
			}
			if k == "LANG" {
				return "C.UTF-8"
			}
			return ""
		}}
	st := r.main(args)
	return out.String(), errb.String(), st
}

var _ = io.Discard

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "bromure-shims-test-")
	if err != nil {
		panic(err)
	}
	paths.SetDataDirForTest(dir)
	code := m.Run()
	os.RemoveAll(dir) // best effort: the log may still be open on Windows
	os.Exit(code)
}
