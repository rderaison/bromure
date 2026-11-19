package delegation

import (
	"bufio"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/paths"
)

func tempSocket(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "dlg")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	paths.SetDataDirForTest(dir)
	return filepath.Join(dir, "d.sock")
}

func startHub(t *testing.T, grace time.Duration) *Hub {
	t.Helper()
	h := NewHub(tempSocket(t))
	h.Grace = grace
	if err := h.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { h.Close() })
	return h
}

// shimRunner runs the shim in-process on pipes.
type shimRunner struct {
	in   *io.PipeWriter
	out  *bufio.Reader
	done chan int
}

func startShim(t *testing.T, h *Hub, hello string) *shimRunner {
	t.Helper()
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	s := &shimRunner{in: inW, out: bufio.NewReader(outR), done: make(chan int, 1)}
	go func() {
		s.done <- runShim(shimOptions{stdin: inR, stdout: outW, socket: h.SocketPath(), hello: hello,
			watchdog: 100 * time.Millisecond, pause: 20 * time.Millisecond})
		outW.Close()
	}()
	t.Cleanup(func() { inW.Close() })
	return s
}

func (s *shimRunner) send(t *testing.T, line string) {
	t.Helper()
	if _, err := s.in.Write([]byte(line + "\n")); err != nil {
		t.Fatal(err)
	}
}

func (s *shimRunner) recv(t *testing.T, within time.Duration) map[string]any {
	t.Helper()
	type res struct {
		line string
		err  error
	}
	ch := make(chan res, 1)
	go func() { l, err := s.out.ReadString('\n'); ch <- res{l, err} }()
	select {
	case r := <-ch:
		if r.err != nil {
			t.Fatalf("shim output: %v", r.err)
		}
		var m map[string]any
		if err := json.Unmarshal([]byte(r.line), &m); err != nil {
			t.Fatalf("not JSON: %q", r.line)
		}
		return m
	case <-time.After(within):
		t.Fatalf("no shim output within %v", within)
	}
	return nil
}

func TestCatalog(t *testing.T) {
	var tools []map[string]any
	if err := json.Unmarshal(Tools(), &tools); err != nil {
		t.Fatal(err)
	}
	if len(tools) != 16 || tools[0]["name"] != "worktree_create" || tools[15]["name"] != "cancel" {
		t.Fatalf("catalog: %d tools", len(tools))
	}
	if !strings.HasPrefix(Instructions(), "Tools for working with OTHER agents through Bromure") ||
		!strings.HasSuffix(Instructions(), "send their reply back with `answer`.") || strings.Contains(Instructions(), "\n") {
		t.Fatalf("instructions: %q…", Instructions()[:60])
	}
	// No HTML escaping on the wire (wt/<name>).
	h := &Hub{}
	out := h.answer(map[string]json.RawMessage{"id": json.RawMessage("1"), "method": json.RawMessage(`"tools/list"`)})
	if !strings.Contains(string(out), "wt/<name>") {
		t.Fatalf("escaped catalog: %.200s", out)
	}
}

func TestLocalFallbackAndRefusal(t *testing.T) {
	h := startHub(t, 300*time.Millisecond)
	s := startShim(t, h, "w3")
	s.send(t, `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`)
	m := s.recv(t, 5*time.Second)
	r := m["result"].(map[string]any)
	if r["protocolVersion"] != "2025-03-26" || r["serverInfo"].(map[string]any)["name"] != "bromure-delegation" {
		t.Fatalf("initialize: %v", m)
	}
	s.send(t, `{"jsonrpc":"2.0","method":"notifications/initialized"}`)
	s.send(t, `{"jsonrpc":"2.0","id":"b","method":"tools/list"}`)
	m = s.recv(t, 5*time.Second)
	if m["id"] != "b" || len(m["result"].(map[string]any)["tools"].([]any)) != 16 {
		t.Fatalf("tools/list: %v", m)
	}
	s.send(t, `{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_peers","arguments":{}}}`)
	m = s.recv(t, 5*time.Second)
	res := m["result"].(map[string]any)
	text := res["content"].([]any)[0].(map[string]any)["text"].(string)
	if m["id"].(float64) != 3 || res["isError"] != true || text != notConnectedText {
		t.Fatalf("refusal: %v", m)
	}
	s.send(t, `{"jsonrpc":"2.0","id":4,"method":"nope"}`)
	m = s.recv(t, 5*time.Second)
	if m["error"].(map[string]any)["code"].(float64) != -32601 {
		t.Fatalf("unknown method: %v", m)
	}
	// stdin EOF ends the shim.
	s.in.Close()
	select {
	case code := <-s.done:
		if code != 0 {
			t.Fatalf("exit %d", code)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("shim didn't exit on stdin EOF")
	}
}

// fakeRelay parks one offer and serves the stream it gets.
type fakeRelay struct {
	got chan Stream
}

func park(h *Hub) *fakeRelay {
	r := &fakeRelay{got: make(chan Stream, 1)}
	h.Park(func(s Stream) bool {
		if s == nil {
			return false
		}
		r.got <- s
		return true
	}, nil)
	return r
}

func (r *fakeRelay) stream(t *testing.T) (Stream, *bufio.Reader) {
	t.Helper()
	select {
	case s := <-r.got:
		return s, bufio.NewReader(s)
	case <-time.After(5 * time.Second):
		t.Fatal("relay got no stream")
	}
	return nil, nil
}

func TestHeldCallGoesToRelay(t *testing.T) {
	h := startHub(t, 10*time.Second)
	s := startShim(t, h, "w3")
	s.send(t, `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`)
	s.recv(t, 5*time.Second)
	// A call with no relay: held by the hub, up to the grace.
	s.send(t, `{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"list_peers","arguments":{}}}`)
	time.Sleep(300 * time.Millisecond)
	// A relay parks: the held stream is kicked, the shim reconnects onto
	// it, says hello and sends the call again.
	relay := park(h)
	st, rd := relay.stream(t)
	defer st.Close()
	hello, _ := rd.ReadString('\n')
	if hello != "bromure-hello w3\n" {
		t.Fatalf("hello: %q", hello)
	}
	call, _ := rd.ReadString('\n')
	if !strings.Contains(call, `"id":7`) || !strings.Contains(call, "list_peers") {
		t.Fatalf("held call: %q", call)
	}
	if _, err := st.Write([]byte(`{"jsonrpc":"2.0","id":7,"result":{"content":[{"type":"text","text":"peers"}]}}` + "\n")); err != nil {
		t.Fatal(err)
	}
	m := s.recv(t, 5*time.Second)
	if m["id"].(float64) != 7 || m["result"].(map[string]any)["content"].([]any)[0].(map[string]any)["text"] != "peers" {
		t.Fatalf("relayed reply: %v", m)
	}
	// The relay drops with a call under way: the agent gets an error
	// reply, never silence; then the shim lands back on the hub.
	s.send(t, `{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"report","arguments":{"text":"x"}}}`)
	line, _ := rd.ReadString('\n')
	if !strings.Contains(line, `"id":8`) {
		t.Fatalf("second call: %q", line)
	}
	st.Close()
	m = s.recv(t, 5*time.Second)
	res := m["result"].(map[string]any)
	if m["id"].(float64) != 8 || res["isError"] != true ||
		res["content"].([]any)[0].(map[string]any)["text"] != lostText {
		t.Fatalf("lost reply: %v", m)
	}
	// Back on the local fallback, which now says "reconnecting".
	h.Grace = 200 * time.Millisecond
	time.Sleep(200 * time.Millisecond)
	s.send(t, `{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"list_peers"}}`)
	m = s.recv(t, 5*time.Second)
	text := m["result"].(map[string]any)["content"].([]any)[0].(map[string]any)["text"]
	if text != reconnectingText {
		t.Fatalf("after a relay: %v", m)
	}
}

func TestStreamGoesStraightToParkedRelay(t *testing.T) {
	h := startHub(t, time.Second)
	relay := park(h)
	if h.ParkedCount() != 1 {
		t.Fatal("not parked")
	}
	s := startShim(t, h, "w-1")
	st, rd := relay.stream(t)
	defer st.Close()
	if l, _ := rd.ReadString('\n'); l != "bromure-hello w-1\n" {
		t.Fatalf("hello %q", l)
	}
	s.send(t, `{"jsonrpc":"2.0","id":1,"method":"ping"}`)
	if l, _ := rd.ReadString('\n'); !strings.Contains(l, `"ping"`) {
		t.Fatalf("ping %q", l)
	}
	st.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":{}}` + "\n"))
	if m := s.recv(t, 5*time.Second); m["id"].(float64) != 1 {
		t.Fatalf("pong %v", m)
	}
}

func TestParkPrunesDeadOffers(t *testing.T) {
	h := startHub(t, time.Second)
	var mu sync.Mutex
	dead := false
	pruned := make(chan bool, 1)
	h.Park(func(s Stream) bool {
		if s == nil {
			pruned <- true
		}
		return false
	}, func() bool { mu.Lock(); defer mu.Unlock(); return !dead })
	mu.Lock()
	dead = true
	mu.Unlock()
	park(h)
	select {
	case <-pruned:
	case <-time.After(time.Second):
		t.Fatal("dead offer not pruned")
	}
	if h.ParkedCount() != 1 {
		t.Fatalf("parked %d", h.ParkedCount())
	}
}

func TestWatchedPeerClosedOnUnixSocket(t *testing.T) {
	path := tempSocket(t)
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	acc := make(chan net.Conn, 1)
	go func() { c, _ := ln.Accept(); acc <- c }()
	c, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	srv := <-acc
	w := Watch(srv)
	time.Sleep(50 * time.Millisecond)
	if w.PeerClosed() || !w.IsOpen() {
		t.Fatal("closed too early")
	}
	c.Write([]byte("hi"))
	// Write-half close (shutdown SD_SEND on Windows): EOF arrives after
	// the data, and the conn can still be written to.
	if err := c.(*net.UnixConn).CloseWrite(); err != nil {
		t.Fatalf("CloseWrite: %v", err)
	}
	time.Sleep(100 * time.Millisecond)
	if w.PeerClosed() {
		t.Fatal("unread data must keep it open")
	}
	b := make([]byte, 8)
	n, _ := w.Read(b)
	if string(b[:n]) != "hi" {
		t.Fatalf("read %q", b[:n])
	}
	deadline := time.Now().Add(2 * time.Second)
	for !w.PeerClosed() && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if !w.PeerClosed() {
		t.Fatal("EOF not seen")
	}
	// The other direction still works after the peer's CloseWrite.
	if _, err := w.Write([]byte("back")); err != nil {
		t.Fatal(err)
	}
	n, _ = c.Read(b)
	if string(b[:n]) != "back" {
		t.Fatalf("reverse %q", b[:n])
	}
	c.Close()
	srv.Close()
}

func TestCallLimits(t *testing.T) {
	cases := []struct {
		line string
		want time.Duration
	}{
		{`{"id":1,"method":"initialize"}`, 60 * time.Second},
		{`{"id":1,"method":"tools/call","params":{"name":"delegate"}}`, untimed},
		{`{"id":1,"method":"tools/call","params":{"name":"report","arguments":{"files":["a"]}}}`, untimed},
		{`{"id":1,"method":"tools/call","params":{"name":"wait","arguments":{"timeout_seconds":10}}}`, 50 * time.Second},
		{`{"id":1,"method":"tools/call","params":{"name":"ask"}}`, 90 * time.Second},
		{`{"id":1,"method":"tools/call","params":{"name":"report"}}`, 300 * time.Second},
	}
	for _, c := range cases {
		var p shimCalls
		p.sent([]byte(c.line), 1, time.Now())
		if len(p.calls) != 1 || p.calls[0].limit != c.want {
			t.Errorf("%s: %v", c.line, p.calls)
		}
	}
	var p shimCalls
	p.sent([]byte(`{"id":5,"method":"tools/call","params":{"name":"report"}}`), 1, time.Now().Add(-301*time.Second))
	if len(p.overdue(time.Now())) != 1 {
		t.Fatal("not overdue")
	}
	p.answered([]byte(`{"id":5,"result":{}}`))
	if len(p.calls) != 0 {
		t.Fatal("not settled")
	}
}

func TestWatchdogDropsSilentRelay(t *testing.T) {
	// A relay that never answers: past the call's deadline the stream the
	// reader is on is shut down, and the call answered as lost at its end.
	ss := newShimStream(nil)
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	gen := ss.open(a)
	go io.Copy(io.Discard, b)
	if r := ss.send([]byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"report"}}`+"\n"), a, gen); r != sendSent {
		t.Fatalf("send %v", r)
	}
	orphans, late := ss.watchdog(time.Now().Add(400 * time.Second))
	if len(orphans) != 0 || late == nil {
		t.Fatalf("watchdog: %v %v", orphans, late)
	}
	if _, _, ok := ss.current(50 * time.Millisecond); ok {
		t.Fatal("stream should be abandoned")
	}
	_, held, _ := ss.ended(a, gen)
	if len(held) != 1 || !strings.Contains(string(lostReply(held[0])), lostText) {
		t.Fatalf("held %v", held)
	}
}
