package panes

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/paths"
)

// The test binary doubles as the program run in windows.
func TestMain(m *testing.M) {
	if mode := os.Getenv("PANES_TEST_CHILD"); mode != "" {
		os.Exit(child(mode))
	}
	if len(os.Args) > 1 && os.Args[1] == "panehost" { // EnsureHost spawned us
		logx.Quiet()
		os.Exit(RunHost())
	}
	dir, err := os.MkdirTemp("", "panes")
	if err != nil {
		panic(err)
	}
	// The env var reaches a spawned pane host; Set... this process.
	os.Setenv("BROMURE_SIDECAR_DATA", dir)
	paths.SetDataDirForTest(dir)
	logx.Quiet()
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

func child(mode string) int {
	switch mode {
	case "echo":
		fmt.Println("hi-there")
		return 7
	case "sleep":
		time.Sleep(60 * time.Second)
	case "env":
		for _, k := range []string{"BROMURE_WINDOW", "TMUX_PANE", "BROMURE_CONTROL", "BROMURE_SIDECAR", "KEEP_ME"} {
			fmt.Printf("%s=[%s]\n", k, os.Getenv(k))
		}
		time.Sleep(60 * time.Second)
	case "attach":
		var idx int
		fmt.Sscan(os.Getenv("PANES_ATTACH_INDEX"), &idx)
		return RunAttach(idx, false)
	case "cat":
		fmt.Println("ready")
		sc := bufio.NewScanner(os.Stdin)
		for sc.Scan() {
			if sc.Text() == "quit" {
				return 0
			}
			fmt.Printf("got:%s\n", sc.Text())
		}
	}
	return 0
}

func childReq(mode string, extraEnv ...string) NewWindowRequest {
	exe, _ := os.Executable()
	env := append(os.Environ(), "PANES_TEST_CHILD="+mode)
	env = append(env, extraEnv...)
	return NewWindowRequest{Name: mode, Argv: []string{exe}, Env: env, Cols: 80, Rows: 24}
}

func waitFor(t *testing.T, what string, d time.Duration, f func() bool) {
	t.Helper()
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if f() {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

func waitCapture(t *testing.T, c Client, idx int, s string) string {
	t.Helper()
	var last string
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		out, err := c.Capture(idx, CaptureOptions{StartHistory: true, Join: true})
		if err == nil {
			last = out
			if strings.Contains(out, s) {
				return out
			}
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("window %d never showed %q; capture:\n%s", idx, s, last)
	return ""
}

func gitBash(t *testing.T) string {
	t.Helper()
	if runtime.GOOS != "windows" {
		p, err := exec.LookPath("bash")
		if err != nil {
			t.Skip("no bash")
		}
		return p
	}
	for _, p := range []string{`C:\Program Files\Git\bin\bash.exe`, `C:\Program Files\Git\usr\bin\bash.exe`} {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	t.Skip("Git Bash not installed")
	return ""
}

func TestWindowLifecycle(t *testing.T) {
	h := NewHost()
	defer h.Close()
	req := childReq("echo")
	req.KeepOnExit = true
	w, err := h.NewWindow(req)
	if err != nil {
		t.Fatal(err)
	}
	if w.Index != 0 || !strings.HasPrefix(w.ID, "@") || !strings.HasPrefix(w.PaneID, "%") ||
		w.TTY != "/dev/pty/bromure-"+w.PaneID[1:] || w.PID <= 0 || w.Width != 80 || w.Height != 24 {
		t.Fatalf("window %+v", w)
	}
	waitFor(t, "exit", 15*time.Second, func() bool { g, _ := h.Get(0); return !g.Alive })
	g, _ := h.Get(0)
	if g.ExitCode == nil || *g.ExitCode != 7 {
		t.Fatalf("exit code %v", g.ExitCode)
	}
	waitCapture(t, h, 0, "hi-there")
	// Without KeepOnExit the window goes with its program.
	w2, err := h.NewWindow(childReq("echo"))
	if err != nil {
		t.Fatal(err)
	}
	if w2.Index != 1 {
		t.Fatalf("second index %d", w2.Index)
	}
	waitFor(t, "window 1 to close", 15*time.Second, func() bool { _, err := h.Get(1); return err != nil })
	if err := h.KillWindow(0); err != nil {
		t.Fatal(err)
	}
	if ws, _ := h.List(true); len(ws) != 0 {
		t.Fatalf("windows left: %+v", ws)
	}
}

func TestIndexAllocationAndOptions(t *testing.T) {
	h := NewHost()
	defer h.Close()
	var ids []string
	for i := 0; i < 3; i++ {
		req := childReq("sleep")
		if i == 2 {
			req.Hidden = true
			req.Options = map[string]string{"@display": "Hidden one"}
		}
		w, err := h.NewWindow(req)
		if err != nil {
			t.Fatal(err)
		}
		if w.Index != i {
			t.Fatalf("index %d, want %d", w.Index, i)
		}
		ids = append(ids, w.ID)
	}
	if ws, _ := h.List(false); len(ws) != 2 {
		t.Fatalf("hidden window listed: %d", len(ws))
	}
	if ws, _ := h.List(true); len(ws) != 3 || ws[2].Options["@display"] != "Hidden one" || !ws[2].Hidden {
		t.Fatalf("list %+v", ws)
	}
	if err := h.KillWindow(1); err != nil {
		t.Fatal(err)
	}
	w, err := h.NewWindow(childReq("sleep"))
	if err != nil {
		t.Fatal(err)
	}
	if w.Index != 1 || w.ID == ids[1] {
		t.Fatalf("reused index %d id %s (old %s)", w.Index, w.ID, ids[1])
	}
	h.SetOption(1, "@worktree", "/home/ubuntu/x")
	if v, ok, _ := h.ShowOption(1, "@worktree"); !ok || v != "/home/ubuntu/x" {
		t.Fatalf("option %q %v", v, ok)
	}
	h.UnsetOption(1, "@worktree")
	if _, ok, _ := h.ShowOption(1, "@worktree"); ok {
		t.Fatal("unset option still set")
	}
	if _, err := h.Get(42); !errorsIs(err, ErrNoWindow) {
		t.Fatalf("Get(42) = %v", err)
	}
	if ws, _ := h.List(false); !ws[0].Active {
		t.Fatalf("first window not active: %+v", ws[0])
	}
	h.SelectWindow(1)
	if ws, _ := h.List(false); ws[0].Active || !ws[1].Active {
		t.Fatal("select-window didn't move the active window")
	}
}

func TestWindowEnv(t *testing.T) {
	h := NewHost()
	defer h.Close()
	w, err := h.NewWindow(childReq("env", "KEEP_ME=yes", "BROMURE_SIDECAR=/opt/custom", "BROMURE_WINDOW=99"))
	if err != nil {
		t.Fatal(err)
	}
	out := waitCapture(t, h, w.Index, "KEEP_ME=")
	for _, want := range []string{
		fmt.Sprintf("BROMURE_WINDOW=[%d]", w.Index), "TMUX_PANE=[" + w.PaneID + "]",
		"BROMURE_CONTROL=[" + paths.ControlSocket() + "]", "BROMURE_SIDECAR=[/opt/custom]", "KEEP_ME=[yes]",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("env lacks %s:\n%s", want, out)
		}
	}
}

func TestSendKeysAndBuffers(t *testing.T) {
	h := NewHost()
	defer h.Close()
	w, err := h.NewWindow(childReq("cat"))
	if err != nil {
		t.Fatal(err)
	}
	waitCapture(t, h, w.Index, "ready")
	if err := h.SendKeys(w.Index, []string{"abc", "Space", "def", "Enter"}, false); err != nil {
		t.Fatal(err)
	}
	waitCapture(t, h, w.Index, "got:abc def")
	if err := h.SendKeys(w.Index, []string{"Enter"}, true); err != nil { // literal: the word
		t.Fatal(err)
	}
	h.SendKeys(w.Index, []string{"Enter"}, false)
	waitCapture(t, h, w.Index, "got:Enter")
	// Paste without bracketed mode on: plain text, LF → CR.
	h.SetBuffer("msg", []byte("line one\nline two\n"))
	if err := h.PasteBuffer("msg", w.Index, true, false, true); err != nil {
		t.Fatal(err)
	}
	waitCapture(t, h, w.Index, "got:line two")
	if err := h.DeleteBuffer("msg"); !errorsIs(err, ErrNoBuffer) {
		t.Fatalf("-d didn't delete the buffer: %v", err)
	}
	h.SendKeys(w.Index, []string{"quit", "Enter"}, false)
	waitFor(t, "exit", 15*time.Second, func() bool { _, err := h.Get(w.Index); return err != nil })
}

func errorsIs(err, target error) bool {
	for err != nil {
		if err == target {
			return true
		}
		u, ok := err.(interface{ Unwrap() error })
		if !ok {
			return false
		}
		err = u.Unwrap()
	}
	return false
}

func TestSizeAuthority(t *testing.T) {
	h := NewHost()
	defer h.Close()
	w, err := h.NewWindow(childReq("sleep"))
	if err != nil {
		t.Fatal(err)
	}
	size := func() (int, int) { g, _ := h.Get(w.Index); return g.Width, g.Height }
	expect := func(step string, c, r int) {
		t.Helper()
		if gc, gr := size(); gc != c || gr != r {
			t.Fatalf("%s: window %dx%d, want %dx%d", step, gc, gr, c, r)
		}
		s, _ := h.Screen(w.Index)
		if s.Width != c || s.Height != r {
			t.Fatalf("%s: screen model %dx%d", step, s.Width, s.Height)
		}
	}
	tick := func() { time.Sleep(2 * time.Millisecond) }
	a, _ := h.Attach(w.Index, 100, 30, false)
	defer a.Close()
	go io.Copy(io.Discard, a)
	expect("A attached", 100, 30)
	tick()
	b, _ := h.Attach(w.Index, 50, 10, true)
	defer b.Close()
	go io.Copy(io.Discard, b)
	expect("passive B attached", 100, 30)
	tick()
	c, _ := h.Attach(w.Index, 120, 40, false)
	defer c.Close()
	go io.Copy(io.Discard, c)
	expect("C attached (latest)", 120, 40)
	tick()
	a.Write([]byte{}) // activity on A
	expect("A typed", 100, 30)
	tick()
	b.Write([]byte{})
	b.Resize(60, 12)
	expect("passive B active", 100, 30)
	cls, _ := h.ListClients()
	if len(cls) != 3 || !strings.Contains(cls[1].Flags, "ignore-size") || strings.Contains(cls[0].Flags, "ignore-size") {
		t.Fatalf("clients %+v", cls)
	}
	tick()
	a.Close()
	expect("A gone", 120, 40)
	h.ResizeWindow(w.Index, 90, 20)
	expect("resize-window", 90, 20)
	c.Resize(130, 45)
	expect("manual size holds", 90, 20)
	h.UnsetOption(w.Index, "window-size")
	expect("window-size unset", 130, 45)
	tick()
	no := false
	if err := h.RefreshClient(cls[1].TTY, &no, 0, 0); err != nil {
		t.Fatal(err)
	}
	expect("B granted, C still latest", 130, 45)
	tick()
	b.Write([]byte{})
	expect("B granted and typed", 60, 12)
	if n, _ := h.DetachSession(""); n != 0 {
		t.Fatal("empty session detached clients")
	}
}

func TestAttachRepaintLiveAndExit(t *testing.T) {
	h := NewHost()
	defer h.Close()
	w, err := h.NewWindow(childReq("cat"))
	if err != nil {
		t.Fatal(err)
	}
	waitCapture(t, h, w.Index, "ready")
	att, err := h.AttachWith(AttachRequest{Index: w.Index, Cols: 80, Rows: 24, Session: "view-test"})
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var got strings.Builder
	done := make(chan struct{})
	go func() {
		buf := make([]byte, 4096)
		for {
			n, err := att.Read(buf)
			mu.Lock()
			got.Write(buf[:n])
			mu.Unlock()
			if err != nil {
				close(done)
				return
			}
		}
	}()
	seen := func(s string) bool { mu.Lock(); defer mu.Unlock(); return strings.Contains(got.String(), s) }
	waitFor(t, "repaint", 5*time.Second, func() bool { return seen("ready") })
	mu.Lock()
	first := got.String()
	mu.Unlock()
	if !strings.HasPrefix(first, "\x1b[0m") {
		t.Errorf("repaint doesn't start with a reset: %q", first[:min(40, len(first))])
	}
	att.Write([]byte("typed\r"))
	waitFor(t, "live output", 10*time.Second, func() bool { return seen("got:typed") })
	if cls, _ := h.ListClients(); len(cls) != 1 || cls[0].Session != "view-test" {
		t.Fatalf("clients %+v", cls)
	}
	att.Write([]byte("quit\r"))
	select {
	case <-done:
	case <-time.After(15 * time.Second):
		t.Fatal("attachment never reached EOF")
	}
	select {
	case <-att.Exited():
	case <-time.After(5 * time.Second):
		t.Fatal("Exited never closed")
	}
	if att.ExitCode() != 0 {
		t.Errorf("exit code %d", att.ExitCode())
	}
}

// Git Bash under ConPTY: readline turns bracketed paste on; a bracketed
// paste lands in the line editor unexecuted.
func TestGitBashBracketedPaste(t *testing.T) {
	bash := gitBash(t)
	h := NewHost()
	defer h.Close()
	env := append(os.Environ(), "PS1=PROMPT$ ", "HOME="+t.TempDir())
	w, err := h.NewWindow(NewWindowRequest{Argv: []string{bash, "--noprofile", "--norc", "-i"}, Env: env, Cols: 100, Rows: 30})
	if err != nil {
		t.Fatal(err)
	}
	waitCapture(t, h, w.Index, "PROMPT$")
	waitFor(t, "mode 2004", 10*time.Second, func() bool { s, _ := h.Screen(w.Index); return s.BracketedPaste })
	if err := h.Paste(w.Index, "echo one-$((1+1))\necho two-$((2+1))", true, true); err != nil {
		t.Fatal(err)
	}
	waitCapture(t, h, w.Index, "echo two-")
	time.Sleep(500 * time.Millisecond)
	if out, _ := h.Capture(w.Index, CaptureOptions{}); strings.Contains(out, "one-2") {
		t.Fatalf("bracketed paste ran before Enter:\n%s", out)
	}
	h.SendKeys(w.Index, []string{"Enter"}, false)
	waitCapture(t, h, w.Index, "two-3")
	out := waitCapture(t, h, w.Index, "one-2")
	_ = out
	// ps view: bash is the root, a running sleep is the foreground.
	h.SendKeys(w.Index, []string{"sleep 30", "Enter"}, false)
	var procs []Proc
	waitFor(t, "sleep in the proc table", 10*time.Second, func() bool {
		procs, _ = h.ProcTable()
		for _, p := range procs {
			if p.Exe == "sleep" {
				return true
			}
		}
		return false
	})
	if len(procs) == 0 || procs[0].PID != w.PID {
		t.Errorf("the root isn't first: %+v", procs)
	}
	for _, p := range procs {
		if p.Window != w.Index || p.TTY != "/dev/pty/bromure-"+w.PaneID[1:] {
			t.Errorf("proc %+v in the wrong window", p)
		}
		switch p.Exe {
		case "bash": // the root, and MSYS fork stubs
			if p.Foreground || !strings.HasPrefix(p.Args, "bash ") {
				t.Errorf("bash row %+v", p)
			}
		case "sleep":
			if !p.Foreground || p.Args != "sleep 30" || p.StartedAt.IsZero() {
				t.Errorf("sleep row %+v", p)
			}
		}
	}
	if g, _ := h.Get(w.Index); g.Command != "sleep" {
		t.Errorf("pane_current_command %q", g.Command)
	}
	h.SendKeys(w.Index, []string{"C-c"}, false)
	waitFor(t, "sleep interrupted", 10*time.Second, func() bool {
		ps, _ := h.ProcTable()
		for _, p := range ps {
			if p.Exe == "sleep" {
				return false
			}
		}
		return true
	})
	time.Sleep(300 * time.Millisecond)
	h.SendKeys(w.Index, []string{"exit", "Enter"}, false)
	waitFor(t, "bash exit", 15*time.Second, func() bool { _, err := h.Get(w.Index); return err != nil })
}

// cmd.exe directly on the ConPTY.
func TestCmdEcho(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("windows only")
	}
	h := NewHost()
	defer h.Close()
	req := NewWindowRequest{Argv: []string{"cmd.exe", "/c", "echo hi from cmd"}, KeepOnExit: true}
	w, err := h.NewWindow(req)
	if err != nil {
		t.Fatal(err)
	}
	waitFor(t, "exit", 15*time.Second, func() bool { g, _ := h.Get(w.Index); return !g.Alive })
	out, _ := h.Capture(w.Index, CaptureOptions{})
	if !strings.HasPrefix(out, "hi from cmd\n") || strings.Count(out, "\n") != 50 {
		t.Errorf("capture %q", out)
	}
}
