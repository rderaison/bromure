package control

import (
	"bufio"
	"bytes"
	"compress/flate"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func startServer(t *testing.T, route Handler) string {
	t.Helper()
	sock := filepath.Join(t.TempDir(), "c.sock")
	s := &Server{Route: route}
	if err := s.Listen(sock); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return sock
}

func roundTrip(t *testing.T, sock, raw string) *http.Response {
	t.Helper()
	c, err := net.Dial("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	c.SetDeadline(time.Now().Add(5 * time.Second))
	io.WriteString(c, raw)
	resp, err := http.ReadResponse(bufio.NewReader(c), nil)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

func TestNoHostHeaderAndBody(t *testing.T) {
	sock := startServer(t, func(r *Request) Response {
		return JSON(200, map[string]any{"path": r.Path, "q": r.Query, "body": r.Body, "method": r.Method})
	})
	body := `{"a":1}`
	resp := roundTrip(t, sock, "POST /x/y?z=1 HTTP/1.1\r\nContent-Length: 7\r\n\r\n"+body)
	if resp.StatusCode != 200 || !resp.Close {
		t.Fatalf("%v %v", resp.StatusCode, resp.Header)
	}
	var out map[string]any
	json.NewDecoder(resp.Body).Decode(&out)
	if out["path"] != "/x/y" || out["q"] != "z=1" || out["body"].(map[string]any)["a"].(float64) != 1 {
		t.Fatalf("%v", out)
	}
}

func TestGzipIsRawDeflate(t *testing.T) {
	big := strings.Repeat("x", 5000)
	sock := startServer(t, func(r *Request) Response { return JSON(200, map[string]any{"s": big}) })
	resp := roundTrip(t, sock, "GET /state HTTP/1.1\r\nHost: localhost\r\nX-Bromure-Gzip: 1\r\nContent-Length: 0\r\n\r\n")
	if resp.Header.Get("X-Bromure-Gzip") != "1" {
		t.Fatal("not compressed")
	}
	data, _ := io.ReadAll(resp.Body)
	plain, err := io.ReadAll(flate.NewReader(bytes.NewReader(data)))
	if err != nil || !strings.Contains(string(plain), big) {
		t.Fatalf("inflate: %v", err)
	}
}

func TestHijackKeepsBufferedBytes(t *testing.T) {
	got := make(chan string, 1)
	sock := startServer(t, func(r *Request) Response {
		c := r.Conn()
		io.WriteString(c, "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n")
		buf := make([]byte, 5)
		io.ReadFull(c, buf)
		got <- string(buf)
		c.Close()
		return Response{}
	})
	c, _ := net.Dial("unix", sock)
	defer c.Close()
	// The frames follow the body in the same write.
	io.WriteString(c, "POST /vms/x/exec HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}hello")
	select {
	case s := <-got:
		if s != "hello" {
			t.Fatal(s)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timeout")
	}
}
