package p2p

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/rderaison/bromure/sidecar/internal/p2p/controlplane"
)

// A fake bromure.io relay (WebSocket server) and a fake sshd (TCP echo): bytes
// the dialer sends through the relay reach the sshd and its reply comes back.
func TestWSRelaySplices(t *testing.T) {
	echo, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer echo.Close()
	go func() {
		for {
			c, err := echo.Accept()
			if err != nil {
				return
			}
			go func() {
				buf := make([]byte, 4096)
				for {
					n, err := c.Read(buf)
					if n > 0 {
						c.Write(append([]byte("echo:"), buf[:n]...))
					}
					if err != nil {
						return
					}
				}
			}()
		}
	}()

	got := make(chan string, 1)
	var sawAuth, sawPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sawAuth, sawPath = r.Header.Get("Authorization"), r.URL.Path
		ws, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		ctx := context.Background()
		ws.Write(ctx, websocket.MessageBinary, []byte("SSH-2.0-test\r\n"))
		_, data, err := ws.Read(ctx)
		if err == nil {
			got <- string(data)
		}
		ws.Close(websocket.StatusNormalClosure, "")
	}))
	defer srv.Close()

	ep, err := controlplane.NewEndpoint(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	joinWSRelay(ep, "tok", "conn-1", echo.Addr().(*net.TCPAddr).Port, nil)
	select {
	case s := <-got:
		if s != "echo:SSH-2.0-test\r\n" {
			t.Fatalf("relayed %q", s)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("no bytes back through the relay")
	}
	if sawAuth != "Bearer tok" || sawPath != "/v1/connections/conn-1/relay" {
		t.Fatalf("join request auth=%q path=%q", sawAuth, sawPath)
	}
}

func TestWSRelayRejectsMalformedIDs(t *testing.T) {
	for _, id := range []string{"", "..", "a/b", "../../devices", "x?y", "a b"} {
		if validConnID(id) {
			t.Fatalf("accepted %q", id)
		}
	}
	if !validConnID("3F2504E0-4F89-11D3-9A0C-0305E82C3301") {
		t.Fatal("rejected a UUID")
	}
}
