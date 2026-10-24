package p2p

import (
	"context"
	"io"
	"net"
	"testing"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/p2p/cptest"
	"github.com/rderaison/bromure/sidecar/internal/p2p/identity"
	"github.com/rderaison/bromure/sidecar/internal/p2p/signal"
	"github.com/rderaison/bromure/sidecar/internal/p2p/turn/turntest"
)

func echo(t *testing.T) int {
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
			go func() { io.Copy(c, c); c.Close() }()
		}
	}()
	return ln.Addr().(*net.TCPAddr).Port
}

func broker(api, token, dev, orgKind string) *Broker {
	b := NewBroker()
	b.Identity = func() (identity.Identity, bool) {
		return identity.Identity{APIBase: api, Bearer: token, InstallID: dev, OrgKind: orgKind}, true
	}
	b.Admit = func(string) bool { return true } // loopback stands in for public addresses
	return b
}

func ping(t *testing.T, c net.Conn, msg string) {
	t.Helper()
	c.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := c.Write([]byte(msg)); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, len(msg))
	if _, err := io.ReadFull(c, buf); err != nil || string(buf) != msg {
		t.Fatalf("echo %q %v", buf, err)
	}
}

// End to end through a fake bromure.io and a fake TURN relay: the server
// broker serves relay-only, the client broker dials it; the winning path is
// the relay, and the bytes reach the server's loopback "SSH server".
func TestServeAndDialThroughRelay(t *testing.T) {
	relay, err := turntest.Start("1700000000:conn", "turn-secret")
	if err != nil {
		t.Fatal(err)
	}
	defer relay.Close()
	cp := cptest.New()
	defer cp.Close()
	cp.TurnURLs, cp.TurnUser, cp.TurnPass = relay.URLs(), "1700000000:conn", "turn-secret"
	cp.AddDevice(&cptest.Device{ID: "dev-server", Token: "tok-server", Name: "Your Mac", Capability: "server"})
	cp.AddDevice(&cptest.Device{ID: "dev-client", Token: "tok-client", Name: "Your PC", Capability: "agent-host"})

	sshPort := echo(t)
	server := broker(cp.URL, "tok-server", "dev-server", "organization")
	defer server.Close()
	server.StartServing(sshPort)
	deadline := time.Now().Add(5 * time.Second)
	for !cp.Online("dev-server") && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if !cp.Online("dev-server") || !cp.Device("dev-server").Server {
		t.Fatal("server never came online in server mode")
	}

	client := broker(cp.URL, "tok-client", "dev-client", "individual")
	defer client.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	conn, err := client.Dial(ctx, "dev-server")
	if err != nil {
		t.Fatal(err)
	}
	ping(t, conn, "SSH-2.0-first\r\n")
	conn.Close()
	if p, ok := client.CachedPath("dev-server"); !ok || p != PathRelay {
		t.Fatalf("path %v %v", p, ok)
	}
	// A second dial reuses the cached relay candidate: no new grant.
	conn2, err := client.Dial(ctx, "dev-server")
	if err != nil {
		t.Fatal(err)
	}
	ping(t, conn2, "SSH-2.0-second\r\n")
	conn2.Close()

	// The organization server reported its side; the personal client didn't.
	// (after its late-srflx window: first srflx + StunBudget + 2 s).
	var done []string
	for end := time.Now().Add(12 * time.Second); time.Now().Before(end); time.Sleep(100 * time.Millisecond) {
		if done = cp.CompletedIDs(); len(done) > 0 {
			break
		}
	}
	if len(done) != 1 || done[0] != "conn-1" {
		t.Fatalf("completed %v", done)
	}
	var binds int
	for _, typ := range relay.Seen() {
		if typ == 0x000B {
			binds++
		}
	}
	if binds != 2 {
		t.Fatalf("%d ConnectionBinds", binds)
	}

	server.StopServing()
	time.Sleep(200 * time.Millisecond)
	if cp.Device("dev-server").Server {
		t.Fatal("server mode still on after StopServing")
	}
}

// A peer that never answers: the dial gives up by the context's deadline.
func TestDialUnreachable(t *testing.T) {
	cp := cptest.New()
	defer cp.Close()
	cp.AddDevice(&cptest.Device{ID: "dev-mute", Token: "tok-mute"})
	cp.AddDevice(&cptest.Device{ID: "dev-client", Token: "tok-client"})
	mute := broker(cp.URL, "tok-mute", "dev-mute", "")
	defer mute.Close()
	ch := mute.ensureChannel(identityOf(mute)) // online, but serves nothing
	if ch == nil {
		t.Fatal("channel")
	}
	ch.OnConnectionOffered = func(signal.ConnectionGrant) {}
	client := broker(cp.URL, "tok-client", "dev-client", "")
	defer client.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	defer cancel()
	t0 := time.Now()
	if _, err := client.Dial(ctx, "dev-mute"); err == nil {
		t.Fatal("dialed a mute peer")
	}
	if time.Since(t0) > 4*time.Second {
		t.Fatalf("took %v", time.Since(t0))
	}
}

func identityOf(b *Broker) identity.Identity { id, _ := b.Identity(); return id }

func TestRaceTakesBestWithinGrace(t *testing.T) {
	good := echo(t)
	cands := []signal.Candidate{
		signal.NewCandidate(signal.KindRelay, signal.ProtoTCP, "127.0.0.1", good, nil),
		signal.NewCandidate(signal.KindHost, signal.ProtoTCP, "127.0.0.1", good, nil),
		signal.NewCandidate(signal.KindHost, signal.ProtoUDP, "127.0.0.1", good, nil), // never raced
	}
	w := dialCandidates(cands, time.Second, time.Now().Add(3*time.Second))
	if w == nil || w.cand.Kind != signal.KindHost || w.path != PathDirect {
		t.Fatalf("winner %+v", w)
	}
	w.conn.Close()
	if isPrivate("172.20.1.1") != true || isPrivate("172.32.1.1") || !isPrivate("FE80::1") {
		t.Fatal("isPrivate")
	}
}
