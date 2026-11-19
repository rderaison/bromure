package sshdial

import (
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"net"
	"os"
	"strings"
	"testing"

	"golang.org/x/crypto/ssh"

	"github.com/rderaison/bromure/sidecar/internal/paths"
)

func setup(t *testing.T) {
	t.Helper()
	// Not t.TempDir: the log file stays open (Windows can't remove it).
	dir, err := os.MkdirTemp("", "sshdial")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	paths.SetDataDirForTest(dir)
}

// testServer accepts the client key for user "u" and execs "echo" back.
func testServer(t *testing.T, hostKey ed25519.PrivateKey, allowed ssh.PublicKey) string {
	t.Helper()
	signer, _ := ssh.NewSignerFromKey(hostKey)
	cfg := &ssh.ServerConfig{PublicKeyCallback: func(m ssh.ConnMetadata, k ssh.PublicKey) (*ssh.Permissions, error) {
		if m.User() == "u" && string(k.Marshal()) == string(allowed.Marshal()) {
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
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				_, chans, reqs, err := ssh.NewServerConn(c, cfg)
				if err != nil {
					return
				}
				go ssh.DiscardRequests(reqs)
				for nc := range chans {
					ch, rq, _ := nc.Accept()
					go func() {
						for r := range rq {
							if r.Type == "exec" {
								var p struct{ Command string }
								ssh.Unmarshal(r.Payload, &p)
								r.Reply(p.Command == "echo", nil)
								if p.Command == "echo" {
									go func() {
										b := make([]byte, 64)
										n, _ := ch.Read(b)
										ch.Write(b[:n])
										ch.CloseWrite()
									}()
								}
							} else if r.WantReply {
								r.Reply(false, nil)
							}
						}
					}()
				}
			}()
		}
	}()
	return ln.Addr().String()
}

func TestClientKeyIsStableAndPublished(t *testing.T) {
	setup(t)
	l1, err := ClientPublicKeyLine()
	if err != nil {
		t.Fatal(err)
	}
	l2, _ := ClientPublicKeyLine()
	if l1 != l2 || !strings.HasPrefix(l1, "ssh-ed25519 ") || !strings.HasSuffix(l1, " bromure-agent-host") {
		t.Fatalf("line %q / %q", l1, l2)
	}
	seed, _ := os.ReadFile(paths.ClientKey())
	if len(seed) != 32 {
		t.Fatalf("seed file is %d bytes", len(seed))
	}
}

func TestTOFUPinAndMismatch(t *testing.T) {
	setup(t)
	signer, _ := ClientSigner()
	_, hk1, _ := ed25519.GenerateKey(rand.Reader)
	_, hk2, _ := ed25519.GenerateKey(rand.Reader)
	a1 := testServer(t, hk1, signer.PublicKey())
	a2 := testServer(t, hk2, signer.PublicKey())
	token := PeerToken("dev-1")

	conn, _ := net.Dial("tcp", a1)
	c, err := Client(conn, "u", token)
	if err != nil {
		t.Fatalf("first contact: %v", err)
	}
	ch, err := OpenExec(c, "echo")
	if err != nil {
		t.Fatal(err)
	}
	ch.Write([]byte("ping"))
	b := make([]byte, 8)
	n, _ := ch.Read(b)
	if string(b[:n]) != "ping" {
		t.Fatalf("echo %q", b[:n])
	}
	if _, err := OpenExec(c, "nope"); !errors.Is(err, ErrExecRefused) {
		t.Fatalf("refused exec: %v", err)
	}
	c.Close()

	kh := DefaultKnownHosts()
	line := kh.PinnedLine(token)
	if !strings.HasPrefix(line, "bromure-peer-dev-1 ssh-ed25519 ") {
		t.Fatalf("pin line %q", line)
	}
	// Same token, the same key: fine.
	conn, _ = net.Dial("tcp", a1)
	if c, err = Client(conn, "u", token); err != nil {
		t.Fatalf("pinned: %v", err)
	}
	c.Close()
	// Same token, another key: refused.
	conn, _ = net.Dial("tcp", a2)
	if _, err = Client(conn, "u", token); !errors.Is(err, ErrHostKeyChanged) {
		t.Fatalf("changed key: %v", err)
	}
	// Strict with no pin: refused.
	conn, _ = net.Dial("tcp", a2)
	if _, err = ClientWith(conn, Options{User: "u", Token: "other", Strict: true}); !errors.Is(err, ErrHostKeyChanged) {
		t.Fatalf("strict: %v", err)
	}
	// Wrong user: auth failed.
	conn, _ = net.Dial("tcp", a1)
	if _, err = Client(conn, "nobody", token); !errors.Is(err, ErrAuthFailed) {
		t.Fatalf("auth: %v", err)
	}
	// Re-pinning replaces, keeping the others.
	kh.Pin("[h]:2222", signer.PublicKey())
	pub2, _ := ssh.NewPublicKey(hk2.Public())
	kh.Pin(token, pub2)
	body, _ := os.ReadFile(kh.Path)
	if strings.Count(string(body), "\n") != 2 || kh.Pinned(token) == nil ||
		string(kh.Pinned(token).Marshal()) != string(pub2.Marshal()) {
		t.Fatalf("known_hosts:\n%s", body)
	}
	if HostToken("h", 22) != "h" || HostToken("h", 2223) != "[h]:2223" {
		t.Fatal("host tokens")
	}
}
