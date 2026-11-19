package panes

import (
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/paths"
)

func startServer(t *testing.T) (string, *Host) {
	t.Helper()
	sock := filepath.Join(t.TempDir(), "p.sock")
	l, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	h := NewHost()
	go Serve(l, h)
	t.Cleanup(func() { l.Close(); h.Close() })
	return sock, h
}

func TestProtocolEndToEnd(t *testing.T) {
	sock, _ := startServer(t)
	c, err := Dial(sock)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	req := childReq("cat")
	req.Options = map[string]string{"@display": "Tab"}
	w, err := c.NewWindow(req)
	if err != nil {
		t.Fatal(err)
	}
	if hi, err := hello(sock); err != nil || hi.Version != HostVersion || hi.Windows != 1 {
		t.Fatalf("hello %+v %v", hi, err)
	}
	waitCapture(t, c, w.Index, "ready")
	ws, err := c.List(false)
	if err != nil || len(ws) != 1 || ws[0].Options["@display"] != "Tab" || ws[0].PID != w.PID {
		t.Fatalf("list %+v %v", ws, err)
	}
	if _, err := c.Get(9); !errors.Is(err, ErrNoWindow) {
		t.Fatalf("remote error lost its kind: %v", err)
	}
	if err := c.SetOption(w.Index, "@bromure_status", "busy"); err != nil {
		t.Fatal(err)
	}
	if v, ok, err := c.ShowOption(w.Index, "@bromure_status"); v != "busy" || !ok || err != nil {
		t.Fatalf("show-option %q %v %v", v, ok, err)
	}
	if err := c.SendKeys(w.Index, []string{"over the wire", "Enter"}, false); err != nil {
		t.Fatal(err)
	}
	waitCapture(t, c, w.Index, "got:over the wire")
	if err := c.SetBuffer("b1", []byte("buffered\n")); err != nil {
		t.Fatal(err)
	}
	if err := c.PasteBuffer("b1", w.Index, true, false, false); err != nil {
		t.Fatal(err)
	}
	waitCapture(t, c, w.Index, "got:buffered")
	if err := c.DeleteBuffer("b1"); err != nil {
		t.Fatal(err)
	}
	if err := c.DeleteBuffer("b1"); !errors.Is(err, ErrNoBuffer) {
		t.Fatalf("second delete: %v", err)
	}
	s, err := c.Screen(w.Index)
	if err != nil || s.Width != 80 || s.Height != 24 || !strings.Contains(s.Text, "got:buffered") {
		t.Fatalf("screen %+v %v", s, err)
	}
	if ps, err := c.ProcTable(); err != nil || len(ps) == 0 || ps[0].PID != w.PID || !ps[0].Foreground {
		t.Fatalf("proc table %+v %v", ps, err)
	}

	// Attach over the socket: repaint, input, resize authority, exit frame.
	att, err := c.AttachWith(AttachRequest{Index: w.Index, Cols: 90, Rows: 20, Session: "view-a"})
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var got strings.Builder
	done := make(chan struct{})
	go func() {
		buf := make([]byte, 1024)
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
	waitFor(t, "repaint over the socket", 5*time.Second, func() bool { return seen("got:buffered") })
	if g, _ := c.Get(w.Index); g.Width != 90 || g.Height != 20 || g.Clients != 1 {
		t.Fatalf("after attach %+v", g)
	}
	att.Resize(70, 15)
	waitFor(t, "resize frame", 5*time.Second, func() bool { g, _ := c.Get(w.Index); return g.Width == 70 && g.Height == 15 })
	cls, _ := c.ListClients()
	if len(cls) != 1 || cls[0].Session != "view-a" || cls[0].Cols != 70 {
		t.Fatalf("clients %+v", cls)
	}
	yes := true
	if err := c.RefreshClient(cls[0].ID, &yes, 0, 0); err != nil {
		t.Fatal(err)
	}
	if cls, _ = c.ListClients(); !strings.Contains(cls[0].Flags, "ignore-size") {
		t.Fatalf("flags %q", cls[0].Flags)
	}
	att.Write([]byte("via attach\r"))
	waitFor(t, "input frame", 10*time.Second, func() bool { return seen("got:via attach") })
	att.Write([]byte("quit\r"))
	select {
	case <-done:
	case <-time.After(15 * time.Second):
		t.Fatal("no EOF after exit")
	}
	select {
	case <-att.Exited():
	case <-time.After(2 * time.Second):
		t.Fatal("no exit frame")
	}
	if att.ExitCode() != 0 {
		t.Fatalf("exit code %d", att.ExitCode())
	}
	att.Close()

	// kill-session -t view-*: the stream ends without an exit frame.
	w2, err := c.NewWindow(childReq("sleep"))
	if err != nil {
		t.Fatal(err)
	}
	a2, err := c.AttachWith(AttachRequest{Index: w2.Index, Cols: 80, Rows: 24, Session: "view-b"})
	if err != nil {
		t.Fatal(err)
	}
	eof := make(chan struct{})
	go func() {
		buf := make([]byte, 1024)
		for {
			if _, err := a2.Read(buf); err != nil {
				close(eof)
				return
			}
		}
	}()
	waitFor(t, "client listed", 5*time.Second, func() bool { cl, _ := c.ListClients(); return len(cl) == 1 })
	if n, err := c.DetachSession("view-b"); n != 1 || err != nil {
		t.Fatalf("detach-session %d %v", n, err)
	}
	select {
	case <-eof:
	case <-time.After(5 * time.Second):
		t.Fatal("detached stream didn't end")
	}
	select {
	case <-a2.Exited():
		t.Fatal("a detach reported an exit")
	default:
	}
	if _, err := c.AttachWith(AttachRequest{Index: 77}); !errors.Is(err, ErrNoWindow) {
		t.Fatalf("attach to nothing: %v", err)
	}
	if err := c.KillWindow(w2.Index); err != nil {
		t.Fatal(err)
	}
}

// RunHost: single instance, answers HostInfo, refuses to stop with windows.
func TestRunHost(t *testing.T) {
	os.Remove(paths.PanesSocket())
	done := make(chan int, 1)
	go func() { done <- RunHost() }()
	waitFor(t, "pane host up", 10*time.Second, func() bool { _, _, err := HostInfo(); return err == nil })
	if rc := RunHost(); rc != 0 {
		t.Fatalf("second instance returned %d", rc)
	}
	c, err := EnsureHost() // connects; must not spawn anything
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.NewWindow(childReq("sleep")); err != nil {
		t.Fatal(err)
	}
	if v, n, err := HostInfo(); v != HostVersion || n != 1 || err != nil {
		t.Fatalf("HostInfo %d %d %v", v, n, err)
	}
	if err := StopHost(false); err == nil {
		t.Fatal("stopped with a window open")
	}
	c.Close()
	if err := StopHost(true); err != nil {
		t.Fatal(err)
	}
	select {
	case rc := <-done:
		if rc != 0 {
			t.Fatalf("RunHost returned %d", rc)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("RunHost didn't return")
	}
	if _, _, err := HostInfo(); err == nil {
		t.Fatal("host still answering")
	}
}

// RunAttach on a real console: the attach client runs in a window of an
// outer host (its terminal is that ConPTY / pty), attached to a window of
// an inner host served on a socket.
func TestRunAttachInConsole(t *testing.T) {
	dir := t.TempDir()
	l, err := net.Listen("unix", filepath.Join(dir, "panes.sock"))
	if err != nil {
		t.Fatal(err)
	}
	inner := NewHost()
	go Serve(l, inner)
	defer func() { l.Close(); inner.Close() }()
	iw, err := inner.NewWindow(childReq("cat"))
	if err != nil {
		t.Fatal(err)
	}
	waitCapture(t, inner, iw.Index, "ready")
	inner.SendKeys(iw.Index, []string{"before attach", "Enter"}, false)
	waitCapture(t, inner, iw.Index, "got:before attach")

	outer := NewHost()
	defer outer.Close()
	req := childReq("attach", "BROMURE_SIDECAR_DATA="+dir, fmt.Sprintf("PANES_ATTACH_INDEX=%d", iw.Index))
	req.Cols, req.Rows = 100, 30
	req.KeepOnExit = true
	ow, err := outer.NewWindow(req)
	if err != nil {
		t.Fatal(err)
	}
	// The repaint shows the inner window's screen in the outer one.
	waitCapture(t, outer, ow.Index, "got:before attach")
	waitFor(t, "attach sized the inner window", 10*time.Second, func() bool {
		g, _ := inner.Get(iw.Index)
		return g.Width == 100 && g.Height == 30 && g.Clients == 1
	})
	outer.SendKeys(ow.Index, []string{"through", "Space", "two", "Space", "hosts", "Enter"}, false)
	waitCapture(t, inner, iw.Index, "got:through two hosts")
	waitCapture(t, outer, ow.Index, "got:through two hosts")
	// C-b C-b sends one C-b; C-b d detaches.
	outer.SendKeys(ow.Index, []string{"C-b", "d"}, false)
	waitCapture(t, outer, ow.Index, "[detached (from session bromure)]")
	waitFor(t, "attach exit", 10*time.Second, func() bool { g, _ := outer.Get(ow.Index); return !g.Alive })
	if g, _ := outer.Get(ow.Index); *g.ExitCode != 0 {
		t.Fatalf("attach exit code %d", *g.ExitCode)
	}
	if g, _ := inner.Get(iw.Index); g.Clients != 0 || !g.Alive {
		t.Fatalf("inner after detach %+v", g)
	}
	// Attach again; the program's exit ends the client.
	ow2, err := outer.NewWindow(req)
	if err != nil {
		t.Fatal(err)
	}
	waitCapture(t, outer, ow2.Index, "got:through two hosts")
	outer.SendKeys(ow2.Index, []string{"quit", "Enter"}, false)
	waitCapture(t, outer, ow2.Index, "[exited]")
}

// EnsureHost with nothing running spawns a detached pane host.
func TestEnsureHostSpawns(t *testing.T) {
	if _, _, err := HostInfo(); err == nil {
		t.Skip("a pane host is already running")
	}
	c, err := EnsureHost()
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if v, n, err := HostInfo(); v != HostVersion || n != 0 || err != nil {
		t.Fatalf("HostInfo %d %d %v", v, n, err)
	}
	w, err := c.NewWindow(childReq("echo"))
	if err != nil {
		t.Fatal(err)
	}
	if w.PID <= 0 {
		t.Fatalf("window %+v", w)
	}
	if err := StopHost(true); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "spawned host gone", 10*time.Second, func() bool { _, _, err := HostInfo(); return err != nil })
}
