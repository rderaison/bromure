// Package ctlclient makes one request on control.sock: HTTP/1.1, one
// request per connection, Connection: close. The tray, `ctl`, the Claude
// hook and the launcher use it.
package ctlclient

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/paths"
)

// Dial connects to the control socket.
func Dial(timeout time.Duration) (net.Conn, error) {
	return net.DialTimeout("unix", paths.ControlSocket(), timeout)
}

// Do sends one request; the status and the raw body.
func Do(method, path string, body any, timeout time.Duration) (int, []byte, error) {
	var payload []byte
	if body != nil {
		switch b := body.(type) {
		case []byte:
			payload = b
		case json.RawMessage:
			payload = b
		default:
			var err error
			if payload, err = json.Marshal(body); err != nil {
				return 0, nil, err
			}
		}
	}
	c, err := Dial(3 * time.Second)
	if err != nil {
		return 0, nil, err
	}
	defer c.Close()
	if timeout > 0 {
		_ = c.SetDeadline(time.Now().Add(timeout))
	}
	head := fmt.Sprintf("%s %s HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n",
		method, path, len(payload))
	if _, err := c.Write(append([]byte(head), payload...)); err != nil {
		return 0, nil, err
	}
	resp, err := http.ReadResponse(bufio.NewReader(c), nil)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	// Stop at Content-Length (never wait for EOF).
	data, err := io.ReadAll(resp.Body)
	return resp.StatusCode, data, err
}

// JSON sends one request and decodes a JSON object reply.
func JSON(method, path string, body any, timeout time.Duration) (int, map[string]any, error) {
	status, data, err := Do(method, path, body, timeout)
	if err != nil {
		return status, nil, err
	}
	out := map[string]any{}
	if len(bytes.TrimSpace(data)) > 0 {
		if err := json.Unmarshal(data, &out); err != nil {
			return status, nil, fmt.Errorf("bad reply (%d): %s", status, truncate(data))
		}
	}
	return status, out, nil
}

// Healthy reports whether a daemon answers /health.
func Healthy() bool {
	status, _, err := Do("GET", "/health", nil, 2*time.Second)
	return err == nil && status == 200
}

func truncate(b []byte) string {
	if len(b) > 200 {
		return string(b[:200]) + "…"
	}
	return string(b)
}

// Itoa is a tiny helper for building paths.
func Itoa(n int) string { return strconv.Itoa(n) }
