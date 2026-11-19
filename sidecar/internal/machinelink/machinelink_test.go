package machinelink

import (
	"bufio"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
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
	"github.com/rderaison/bromure/sidecar/internal/paths"
	"github.com/rderaison/bromure/sidecar/internal/settings"
	"github.com/rderaison/bromure/sidecar/internal/sshdial"
	"github.com/rderaison/bromure/sidecar/internal/sshserver"
)

const hostID = "1B4E28BA-2FA1-11D2-883F-0016D3CCA427"

// fakeServer is an account server's SSH side of MachineLinks: it parks
// machine-link channels after answering with header().
type fakeServer struct {
	addr    string
	header  func() string
	links   chan ssh.Channel
	mu      sync.Mutex
	verbs   []string
	conns   int
	detachd chan string
}

func startServer(t *testing.T, client ssh.PublicKey, header func() string) *fakeServer {
	t.Helper()
	_, hk, _ := ed25519.GenerateKey(rand.Reader)
	signer, _ := ssh.NewSignerFromKey(hk)
	cfg := &ssh.ServerConfig{PublicKeyCallback: func(m ssh.ConnMetadata, k ssh.PublicKey) (*ssh.Permissions, error) {
		if m.User() == "me" && string(k.Marshal()) == string(client.Marshal()) {
			return nil, nil
		}
		return nil, errors.New("no")
	}}
	cfg.AddHostKey(signer)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	fs := &fakeServer{addr: ln.Addr().String(), header: header, links: make(chan ssh.Channel, 16), detachd: make(chan string, 4)}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				sc, chans, reqs, err := ssh.NewServerConn(c, cfg)
				if err != nil {
					return
				}
				defer sc.Close()
				fs.mu.Lock()
				fs.conns++
				fs.mu.Unlock()
				go ssh.DiscardRequests(reqs)
				for nc := range chans {
					ch, rq, _ := nc.Accept()
					go func() {
						for r := range rq {
							if r.Type != "exec" {
								r.Reply(false, nil)
								continue
							}
							var p struct{ Command string }
							ssh.Unmarshal(r.Payload, &p)
							fs.mu.Lock()
							fs.verbs = append(fs.verbs, p.Command)
							fs.mu.Unlock()
							switch {
							case strings.HasPrefix(p.Command, sshserver.MachineLinkVerbPrefix):
								r.Reply(true, nil)
								ch.Write([]byte(fs.header()))
								fs.links <- ch
							case strings.HasPrefix(p.Command, sshserver.MachineDetachVerbPrefix):
								r.Reply(true, nil)
								ch.Write([]byte("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
								ch.Close()
								fs.detachd <- p.Command
							default:
								r.Reply(false, nil)
							}
						}
					}()
				}
			}()
		}
	}()
	return fs
}

func (fs *fakeServer) link(t *testing.T) ssh.Channel {
	t.Helper()
	select {
	case ch := <-fs.links:
		return ch
	case <-time.After(10 * time.Second):
		t.Fatal("no link parked")
	}
	return nil
}

// fakeControl answers one HTTP request per connection.
func fakeControl(t *testing.T, dir string) string {
	t.Helper()
	p := filepath.Join(dir, "c.sock")
	ln, err := net.Listen("unix", p)
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
				out := `{"path":"` + req.URL.Path + `"}`
				c.Write([]byte("HTTP/1.1 200 OK\r\nContent-Length: " + strconv.Itoa(len(out)) + "\r\n\r\n" + out))
				io.Copy(io.Discard, br) // until the far end's EOF
			}()
		}
	}()
	return p
}

type env struct {
	dir string
	hub *delegation.Hub
	ctl string
}

func setup(t *testing.T) *env {
	t.Helper()
	dir, err := os.MkdirTemp("", "mlink")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	paths.SetDataDirForTest(dir)
	settings.ResetForTest()
	hub := delegation.NewHub(filepath.Join(dir, "d.sock"))
	if err := hub.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.Close() })
	return &env{dir: dir, hub: hub, ctl: fakeControl(t, dir)}
}

func (e *env) linker(fs *fakeServer) *Linker {
	l := New(Config{
		Dial: func(ctx context.Context, id string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "tcp", fs.addr)
		},
		MachineName:   func() string { return "Win Box" },
		HostID:        func() string { return hostID },
		ControlSocket: e.ctl,
		Hub:           e.hub,
	})
	l.unit = 50 * time.Millisecond
	l.maxBackoff = 200 * time.Millisecond
	l.refusedPause = 200 * time.Millisecond
	return l
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestTargetJSON(t *testing.T) {
	b, _ := json.Marshal(Target{ID: "d1", Name: "Ark", User: "me"})
	if string(b) != `{"device":{"id":"d1","name":"Ark","user":"me"}}` {
		t.Fatalf("encoded %s", b)
	}
	var tt Target
	if err := json.Unmarshal([]byte(`{"device":{"id":"d2","name":"N","user":"u"}}`), &tt); err != nil || tt != (Target{"d2", "N", "u"}) {
		t.Fatalf("decoded %+v %v", tt, err)
	}
	if err := json.Unmarshal([]byte(`{"local":{}}`), &tt); !errors.Is(err, ErrLocalTarget) {
		t.Fatalf("local: %v", err)
	}
}

func TestLinksParkAndServeVerbs(t *testing.T) {
	e := setup(t)
	signer, err := sshdial.ClientSigner()
	if err != nil {
		t.Fatal(err)
	}
	var pending = true
	var mu sync.Mutex
	fs := startServer(t, signer.PublicKey(), func() string {
		mu.Lock()
		defer mu.Unlock()
		if pending {
			return "HTTP/1.1 200 OK\r\nX-Bromure-Fleet: pending\r\nContent-Length: 0\r\n\r\n"
		}
		return "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
	})
	l := e.linker(fs)
	target := Target{ID: "dev-srv", Name: "Ark", User: "me"}
	l.Attach(target)
	links := []ssh.Channel{fs.link(t), fs.link(t), fs.link(t)}
	waitFor(t, "linked", func() bool { st := l.Status(); return st.Linked && st.AwaitingApproval })
	st := l.Status()
	if st.Target == nil || *st.Target != target || st.Error != "" {
		t.Fatalf("status %+v", st)
	}
	fs.mu.Lock()
	verb, conns := fs.verbs[0], fs.conns
	fs.mu.Unlock()
	name := base64.StdEncoding.EncodeToString([]byte("Win Box"))
	if verb != "bromure-fatclient/1 machine-link "+hostID+" "+name {
		t.Fatalf("verb %q", verb)
	}
	if conns != 1 {
		t.Fatalf("%d SSH connections for 3 links (want one, pooled)", conns)
	}
	raw, _ := os.ReadFile(paths.SettingsFile())
	if !strings.Contains(string(raw), `"attach.target": {`) || !strings.Contains(string(raw), `"device"`) {
		t.Fatalf("settings: %s", raw)
	}
	mu.Lock()
	pending = false
	mu.Unlock()

	// control: the server's request, answered by our control API; its
	// EOF travels on and the link ends.
	c := links[0]
	c.Write([]byte("control\nGET /state HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n"))
	br := bufio.NewReader(c)
	resp, err := http.ReadResponse(br, nil)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	if string(body) != `{"path":"/state"}` {
		t.Fatalf("body %q", body)
	}
	waitFor(t, "approved", func() bool { return !l.Status().AwaitingApproval })
	c.CloseWrite()
	if _, err := br.ReadByte(); err != io.EOF {
		t.Fatalf("link after control: %v", err)
	}
	fs.link(t) // a fresh one parks in its place

	// delegation-mcp: carries the next agent MCP stream.
	d := links[1]
	d.Write([]byte("delegation-mcp\n"))
	waitFor(t, "parked in the hub", func() bool { return e.hub.ParkedCount() == 1 })
	shim, err := net.Dial("unix", e.hub.SocketPath())
	if err != nil {
		t.Fatal(err)
	}
	shim.Write([]byte("bromure-hello w2\n"))
	dr := bufio.NewReader(d)
	if line, _ := dr.ReadString('\n'); line != "bromure-hello w2\n" {
		t.Fatalf("hello %q", line)
	}
	d.Write([]byte("{\"id\":1}\n"))
	b := make([]byte, 32)
	n, _ := shim.Read(b)
	if string(b[:n]) != "{\"id\":1}\n" {
		t.Fatalf("to shim %q", b[:n])
	}
	shim.Close()

	// Detach and forget: links closed, the server told, the target gone.
	l.Detach(true)
	if _, err := bufio.NewReader(links[2]).ReadByte(); err == nil {
		t.Fatal("parked link survived the detach")
	}
	select {
	case v := <-fs.detachd:
		if v != "bromure-fatclient/1 machine-detach "+hostID {
			t.Fatalf("detach verb %q", v)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("no machine-detach")
	}
	settings.ResetForTest()
	if settings.Has(settings.AttachTarget) {
		t.Fatal("target not forgotten")
	}
	if st := l.Status(); st.Target != nil || st.Linked {
		t.Fatalf("after detach %+v", st)
	}
}

func TestRefusedAndUnreachable(t *testing.T) {
	e := setup(t)
	signer, _ := sshdial.ClientSigner()
	body := `{"error":"Blocked on Ark"}`
	fs := startServer(t, signer.PublicKey(), func() string {
		return "HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nContent-Length: " +
			strconv.Itoa(len(body)) + "\r\n\r\n" + body
	})
	l := e.linker(fs)
	l.Attach(Target{ID: "dev-srv", Name: "Ark", User: "me"})
	waitFor(t, "refusal", func() bool { return l.Status().Error == "Ark: Blocked on Ark" })
	if l.Status().Linked {
		t.Fatal("linked while refused")
	}
	l.Detach(false)

	// Nothing listening: "Can't reach".
	dead := &fakeServer{addr: "127.0.0.1:1"}
	l2 := e.linker(dead)
	l2.Attach(Target{ID: "dev-x", Name: "Gone", User: "me"})
	waitFor(t, "unreachable", func() bool { return l2.Status().Error == "Can't reach Gone" })
	l2.Detach(false)

	// Resume picks the stored target up again.
	l3 := e.linker(fs)
	l3.Resume()
	if st := l3.Status(); st.Target == nil || st.Target.Name != "Gone" {
		t.Fatalf("resume %+v", st)
	}
	l3.Detach(true)
}

func TestReadAcceptedStopsAtContentLength(t *testing.T) {
	// The verb line follows the header on the same stream: nothing past
	// the body may be consumed.
	r := strings.NewReader("HTTP/1.1 403 Forbidden\r\nContent-Length: 13\r\n\r\n{\"error\":\"x\"}control\n")
	a := readAccepted(r)
	if a.kind != refused || a.why != "x" {
		t.Fatalf("%+v", a)
	}
	rest, _ := io.ReadAll(r)
	if string(rest) != "control\n" {
		t.Fatalf("over-read: %q", rest)
	}
	r = strings.NewReader("HTTP/1.1 200 OK\r\nX-Bromure-Fleet: pending\r\n\r\ncontrol\n")
	if a := readAccepted(r); a.kind != accepted || !a.pending {
		t.Fatalf("%+v", a)
	}
	if v, ok := readLine(r); !ok || v != "control" {
		t.Fatalf("verb %q", v)
	}
	if a := readAccepted(strings.NewReader("HTTP/1.1 500 X\r\n\r\n")); a.kind != failed {
		t.Fatalf("%+v", a)
	}
	if a := readAccepted(strings.NewReader("HTTP/1.1 200")); a.kind != failed {
		t.Fatalf("EOF mid-header: %+v", a)
	}
}
