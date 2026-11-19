package sshserver

import (
	"bufio"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/rderaison/bromure/sidecar/internal/delegation"
	"github.com/rderaison/bromure/sidecar/internal/panes"
	"github.com/rderaison/bromure/sidecar/internal/paths"
)

// fakeControl is a control.sock: one HTTP request per connection, a
// Content-Length reply, then it waits for the client's EOF.
type fakeControl struct {
	path string
	mu   sync.Mutex
	reqs []string // "METHOD path body"
	eofs int
}

func startControl(t *testing.T, dir string) *fakeControl {
	t.Helper()
	fc := &fakeControl{path: filepath.Join(dir, "c.sock")}
	ln, err := net.Listen("unix", fc.path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				br := bufio.NewReader(c)
				req, err := http.ReadRequest(br)
				if err != nil {
					return
				}
				body, _ := io.ReadAll(req.Body)
				fc.mu.Lock()
				fc.reqs = append(fc.reqs, req.Method+" "+req.URL.Path+" "+string(body))
				fc.mu.Unlock()
				out := `{"ok":true,"path":"` + req.URL.Path + `"}`
				c.Write([]byte("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " +
					strconv.Itoa(len(out)) + "\r\n\r\n" + out))
				// Stay open until the client is done writing.
				io.Copy(io.Discard, br)
				fc.mu.Lock()
				fc.eofs++
				fc.mu.Unlock()
			}()
		}
	}()
	return fc
}

func (fc *fakeControl) requests() []string {
	fc.mu.Lock()
	defer fc.mu.Unlock()
	return append([]string(nil), fc.reqs...)
}

type env struct {
	srv  *Server
	ctl  *fakeControl
	hub  *delegation.Hub
	dir  string
	addr string
}

func setup(t *testing.T, pane func() (panes.Client, error)) *env {
	t.Helper()
	dir, err := os.MkdirTemp("", "sshsrv")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	paths.SetDataDirForTest(dir)
	ctl := startControl(t, dir)
	hub := delegation.NewHub(filepath.Join(dir, "d.sock"))
	if err := hub.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.Close() })
	srv, err := Start(Config{Port: 0, User: "tester", ControlSocket: ctl.path, Hub: hub, Panes: pane})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(srv.Close)
	return &env{srv: srv, ctl: ctl, hub: hub, dir: dir, addr: srv.Addr().String()}
}

func newKey(t *testing.T, comment string) (ssh.Signer, string) {
	t.Helper()
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	s, _ := ssh.NewSignerFromKey(priv)
	return s, "ssh-ed25519 " + base64.StdEncoding.EncodeToString(s.PublicKey().Marshal()) + " " + comment
}

func (e *env) dial(t *testing.T, user string, key ssh.Signer) (*ssh.Client, error) {
	t.Helper()
	hostLine := HostPublicKeyLine()
	hostKey, _, _, _, err := ssh.ParseAuthorizedKey([]byte(hostLine))
	if err != nil {
		t.Fatalf("host key line %q: %v", hostLine, err)
	}
	return ssh.Dial("tcp", e.addr, &ssh.ClientConfig{
		User: user, Auth: []ssh.AuthMethod{ssh.PublicKeys(key)},
		HostKeyCallback: ssh.FixedHostKey(hostKey), Timeout: 5 * time.Second,
	})
}

func TestControlBridgeEndToEnd(t *testing.T) {
	e := setup(t, nil)
	key, line := newKey(t, "laptop")
	if err := e.srv.AddAuthorizedKey(line); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(HostKeyFingerprint(), "256 SHA256:") || !strings.HasSuffix(HostKeyFingerprint(), " bromure-ac-remote (ED25519)") {
		t.Fatalf("fingerprint %q", HostKeyFingerprint())
	}
	if seed, _ := os.ReadFile(paths.HostKey()); len(seed) != 32 {
		t.Fatalf("host key file %d bytes", len(seed))
	}
	c, err := e.dial(t, "tester", key)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	sess, _ := c.NewSession()
	stdin, _ := sess.StdinPipe()
	stdout, _ := sess.StdoutPipe()
	if err := sess.Start(ControlVerb); err != nil {
		t.Fatal(err)
	}
	stdin.Write([]byte("GET /health HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n"))
	resp, err := http.ReadResponse(bufio.NewReader(stdout), nil)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body) // stops at Content-Length
	if resp.StatusCode != 200 || string(body) != `{"ok":true,"path":"/health"}` {
		t.Fatalf("reply %d %q", resp.StatusCode, body)
	}
	// Our EOF reaches control.sock as a write-half close; its close comes
	// back as exit-status 0.
	stdin.Close()
	done := make(chan error, 1)
	go func() { done <- sess.Wait() }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("exit: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("no exit-status after EOF")
	}
	e.ctl.mu.Lock()
	eofs := e.ctl.eofs
	e.ctl.mu.Unlock()
	if eofs != 1 {
		t.Fatalf("control saw %d EOFs", eofs)
	}

	// Refused: wrong user, unknown key, other channel types, forwards.
	if _, err := e.dial(t, "someone", key); err == nil {
		t.Fatal("wrong user accepted")
	}
	other, _ := newKey(t, "x")
	if _, err := e.dial(t, "tester", other); err == nil {
		t.Fatal("unknown key accepted")
	}
	if _, err := c.Dial("tcp", "127.0.0.1:9"); err == nil {
		t.Fatal("direct-tcpip accepted")
	}
	for _, verb := range []string{"bromure-fatclient/1 forward 192.168.64.2 22", "bromure-fatclient/1 forward-udp 192.168.64.2", "bromure-fatclient/1 browser-mcp ws1"} {
		s, _ := c.NewSession()
		if err := s.Start(verb); err == nil {
			t.Fatalf("%s accepted", verb)
		}
	}
	s, _ := c.NewSession()
	if err := s.Setenv("FOO", "bar"); err == nil {
		t.Fatal("env accepted")
	}
	if err := s.RequestSubsystem("sftp"); err == nil {
		t.Fatal("subsystem accepted")
	}
	if ok, _, _ := c.SendRequest("tcpip-forward", true, nil); ok {
		t.Fatal("global request accepted")
	}
}

func TestAuthorizedKeysManagement(t *testing.T) {
	e := setup(t, nil)
	k1, l1 := newKey(t, "one")
	_, l2 := newKey(t, "two")
	if err := AddAuthorizedKey("  " + l1 + "\n"); err != nil {
		t.Fatal(err)
	}
	if err := AddAuthorizedKey(l2); err != nil {
		t.Fatal(err)
	}
	// Same key again, new comment: replaced, not duplicated.
	if err := AddAuthorizedKey(strings.Replace(l1, " one", " uno", 1)); err != nil {
		t.Fatal(err)
	}
	keys := ListAuthorizedKeys()
	if len(keys) != 2 || keys[0].Comment != "two" || keys[1].Comment != "uno" {
		t.Fatalf("keys %+v", keys)
	}
	if err := AddAuthorizedKey("ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ== x"); !errors.Is(err, ErrBadKey) {
		t.Fatalf("rsa: %v", err)
	}
	if err := AddAuthorizedKey("garbage"); err == nil {
		t.Fatal("garbage accepted")
	}
	// Managed keys: added beside the manual ones, a duplicate of a manual
	// blob dropped, replaced as a set.
	_, m1 := newKey(t, AccountKeyMarker+"dev-a")
	_, m2 := newKey(t, AccountKeyMarker+"dev-b")
	dup := strings.Replace(l2, " two", " "+AccountKeyMarker+"dup", 1)
	SetManagedKeys(AccountKeyMarker, []string{m1, dup, "bad line"})
	keys = ListAuthorizedKeys()
	if len(keys) != 3 || keys[2].Line != m1 {
		t.Fatalf("managed %+v", keys)
	}
	st1, _ := os.Stat(paths.AuthorizedKeys())
	time.Sleep(20 * time.Millisecond)
	SetManagedKeys(AccountKeyMarker, []string{m1}) // unchanged: no write
	st2, _ := os.Stat(paths.AuthorizedKeys())
	if !st1.ModTime().Equal(st2.ModTime()) {
		t.Fatal("unchanged managed set rewrote the file")
	}
	SetManagedKeys(AccountKeyMarker, []string{m2})
	keys = ListAuthorizedKeys()
	if len(keys) != 3 || keys[2].Line != m2 || keys[0].Comment != "two" {
		t.Fatalf("replaced %+v", keys)
	}
	// Remove by 1-based index, then by fingerprint substring.
	if err := RemoveAuthorizedKey("1"); err != nil {
		t.Fatal(err)
	}
	keys = ListAuthorizedKeys()
	if len(keys) != 2 || keys[0].Comment != "uno" {
		t.Fatalf("after index remove %+v", keys)
	}
	fp := keys[1].Fingerprint
	if err := RemoveAuthorizedKey(fp[len(fp)-10:]); err != nil {
		t.Fatal(err)
	}
	keys = ListAuthorizedKeys()
	if len(keys) != 1 || keys[0].Comment != "uno" {
		t.Fatalf("after fingerprint remove %+v", keys)
	}
	// Hot-swapped into the running server: the remaining key logs in, a
	// removed one doesn't.
	c, err := e.dial(t, "tester", k1)
	if err != nil {
		t.Fatalf("after reload: %v", err)
	}
	c.Close()
	RemoveAuthorizedKey(keys[0].Fingerprint)
	if _, err := e.dial(t, "tester", k1); err == nil {
		t.Fatal("removed key still accepted")
	}
}

func TestMachineOnlyKey(t *testing.T) {
	e := setup(t, func() (panes.Client, error) { return nil, errors.New("unused") })
	key, line := newKey(t, MachineKeyMarker+"dev-42")
	SetManagedKeys(AccountKeyMarker, []string{line})
	c, err := e.dial(t, "tester", key)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	for _, verb := range []string{ControlVerb, DelegationMCPVerb, "ls"} {
		s, _ := c.NewSession()
		if err := s.Start(verb); err == nil {
			t.Fatalf("machine key ran %q", verb)
		}
	}
	s, _ := c.NewSession()
	if err := s.Shell(); err == nil {
		t.Fatal("machine key got a shell")
	}
	// machine-link: the control socket gets the request we wrote, with the
	// owner from the key, never from the client.
	id := "1b4e28ba-2fa1-11d2-883f-0016d3cca427"
	s, _ = c.NewSession()
	out, _ := s.StdoutPipe()
	in, _ := s.StdinPipe()
	if err := s.Start(MachineLinkVerb(id, "Box \"one\"")); err != nil {
		t.Fatal(err)
	}
	resp, err := http.ReadResponse(bufio.NewReader(out), nil)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	in.Close()
	s.Wait()
	reqs := e.ctl.requests()
	want := `POST /machines/link {"id":"1B4E28BA-2FA1-11D2-883F-0016D3CCA427","name":"Box \"one\"","owner":"device:dev-42"}`
	if len(reqs) != 1 || reqs[0] != want {
		t.Fatalf("requests %q", reqs)
	}
	s, _ = c.NewSession()
	if err := s.Start(MachineDetachVerb(id)); err != nil {
		t.Fatal(err)
	}
	s.Wait()
	reqs = e.ctl.requests()
	if len(reqs) != 2 || reqs[1] != `POST /machines/detach {"id":"1B4E28BA-2FA1-11D2-883F-0016D3CCA427","owner":"device:dev-42"}` {
		t.Fatalf("detach %q", reqs)
	}
}

func TestDelegationMCPParksUntilAStream(t *testing.T) {
	e := setup(t, nil)
	key, line := newKey(t, "mac")
	AddAuthorizedKey(line)
	c, err := e.dial(t, "tester", key)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	s, _ := c.NewSession()
	out, _ := s.StdoutPipe()
	in, _ := s.StdinPipe()
	if err := s.Start(DelegationMCPVerb); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for e.hub.ParkedCount() != 1 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if e.hub.ParkedCount() != 1 {
		t.Fatal("not parked")
	}
	// An agent's shim connects: its stream is spliced to the channel.
	shim, err := net.Dial("unix", e.hub.SocketPath())
	if err != nil {
		t.Fatal(err)
	}
	defer shim.Close()
	shim.Write([]byte("bromure-hello w5\n"))
	br := bufio.NewReader(out)
	if l, _ := br.ReadString('\n'); l != "bromure-hello w5\n" {
		t.Fatalf("hello %q", l)
	}
	in.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":{}}` + "\n"))
	b := make([]byte, 128)
	n, _ := shim.Read(b)
	if !strings.Contains(string(b[:n]), `"id":1`) {
		t.Fatalf("to shim %q", b[:n])
	}
	shim.Close()
	done := make(chan error, 1)
	go func() { done <- s.Wait() }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("exit %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("channel didn't end with the stream")
	}
}

// MARK: the remote menu, on a fake pane host

type fakeAtt struct {
	r       *io.PipeReader
	w       *io.PipeWriter
	mu      sync.Mutex
	input   []byte
	sizes   [][2]int
	exited  chan struct{}
	closeMu sync.Once
}

func (a *fakeAtt) Read(p []byte) (int, error) { return a.r.Read(p) }
func (a *fakeAtt) Write(p []byte) (int, error) {
	a.mu.Lock()
	a.input = append(a.input, p...)
	a.mu.Unlock()
	return len(p), nil
}
func (a *fakeAtt) Close() error { a.closeMu.Do(func() { a.w.Close() }); return nil }
func (a *fakeAtt) Resize(c, r int) error {
	a.mu.Lock()
	a.sizes = append(a.sizes, [2]int{c, r})
	a.mu.Unlock()
	return nil
}
func (a *fakeAtt) Exited() <-chan struct{} { return a.exited }
func (a *fakeAtt) ExitCode() int           { return 0 }

// fakePanes implements what the menu uses; the rest of panes.Client is
// the embedded nil interface (never called).
type fakePanes struct {
	panes.Client
	mu      sync.Mutex
	att     *fakeAtt
	attachd chan [3]int
}

func (f *fakePanes) List(bool) ([]panes.Window, error) {
	return []panes.Window{
		{Index: 0, Name: "claude", Cwd: "/home/ubuntu/src/app", Alive: true},
		{Index: 1, Name: "codex", Cwd: "/home/ubuntu/src/lib", Alive: true, Options: map[string]string{"@display": "Lib work"}},
	}, nil
}
func (f *fakePanes) Attach(i, c, r int, passive bool) (panes.Attachment, error) {
	pr, pw := io.Pipe()
	a := &fakeAtt{r: pr, w: pw, exited: make(chan struct{})}
	f.mu.Lock()
	f.att = a
	f.mu.Unlock()
	f.attachd <- [3]int{i, c, r}
	go pw.Write([]byte("AGENT-SCREEN"))
	return a, nil
}
func (f *fakePanes) Close() error { return nil }

// readUntil reads r until s shows up.
func readUntil(t *testing.T, r io.Reader, s string) {
	t.Helper()
	got := make(chan bool, 1)
	go func() {
		var acc []byte
		b := make([]byte, 4096)
		for {
			n, err := r.Read(b)
			acc = append(acc, b[:n]...)
			if strings.Contains(string(acc), s) {
				got <- true
				return
			}
			if err != nil {
				got <- false
				return
			}
		}
	}()
	select {
	case ok := <-got:
		if !ok {
			t.Fatalf("stream ended before %q", s)
		}
	case <-time.After(5 * time.Second):
		t.Fatalf("no %q", s)
	}
}

func TestRemoteMenuAttaches(t *testing.T) {
	fp := &fakePanes{attachd: make(chan [3]int, 1)}
	e := setup(t, func() (panes.Client, error) { return fp, nil })
	key, line := newKey(t, "phone")
	AddAuthorizedKey(line)
	c, err := e.dial(t, "tester", key)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	s, _ := c.NewSession()
	out, _ := s.StdoutPipe()
	in, _ := s.StdinPipe()
	if err := s.RequestPty("xterm-256color", 40, 120, nil); err != nil {
		t.Fatal(err)
	}
	if err := s.Shell(); err != nil {
		t.Fatal(err)
	}
	readUntil(t, out, "Lib work")
	in.Write([]byte("\x1b[B\r")) // down, Enter: window 1
	select {
	case a := <-fp.attachd:
		if a != [3]int{1, 120, 40} {
			t.Fatalf("attach %v", a)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("no attach")
	}
	readUntil(t, out, "AGENT-SCREEN")
	in.Write([]byte("hi\x02\x02"))
	s.WindowChange(50, 160)
	time.Sleep(200 * time.Millisecond)
	fp.mu.Lock()
	att := fp.att
	fp.mu.Unlock()
	att.mu.Lock()
	input, sizes := string(att.input), att.sizes
	att.mu.Unlock()
	if input != "hi\x02" || len(sizes) == 0 || sizes[len(sizes)-1] != [2]int{160, 50} {
		t.Fatalf("input %q sizes %v", input, sizes)
	}
	in.Write([]byte("\x02d")) // detach: back to the list
	readUntil(t, out, "Detached.")
	in.Write([]byte("q"))
	done := make(chan error, 1)
	go func() { done <- s.Wait() }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("exit %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("menu didn't quit")
	}
}
