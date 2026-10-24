package sockopt

import (
	"io"
	"net"
	"testing"
	"time"
)

func pair(t *testing.T) (net.Conn, net.Conn) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	ch := make(chan net.Conn, 1)
	go func() { c, _ := ln.Accept(); ch <- c }()
	a, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	return a, <-ch
}

// The options apply without error on a real socket and the half-close
// survives the splice: one side's EOF reaches the other while the reverse
// direction still flows.
func TestTuneAndSplice(t *testing.T) {
	a1, a2 := pair(t)
	b1, b2 := pair(t)
	TuneInteractive(a1, true)
	SetUserTimeout(a1, 60)
	BoundStalledPeer(b1)
	done := make(chan struct{})
	go func() { Splice(a2, b1, true, false); close(done) }()

	a1.SetDeadline(time.Now().Add(5 * time.Second))
	b2.SetDeadline(time.Now().Add(5 * time.Second))
	a1.Write([]byte("ping"))
	a1.(*net.TCPConn).CloseWrite()
	got, err := io.ReadAll(b2)
	if err != nil || string(got) != "ping" {
		t.Fatalf("a->b %q %v", got, err)
	}
	b2.Write([]byte("pong"))
	b2.Close()
	back, err := io.ReadAll(a1)
	if err != nil || string(back) != "pong" {
		t.Fatalf("b->a %q %v", back, err)
	}
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("splice didn't end")
	}
	a1.Close()
}
