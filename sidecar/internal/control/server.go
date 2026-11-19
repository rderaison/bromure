// Package control is the Sidecar's control socket: the subset of Bromure
// AC's control API (AutomationServer.swift) a fat client needs to mirror
// this machine as one machine with agent sessions — /state, /vms, exec
// (plain and the framed PTY stream behind every terminal), file ops,
// agent-session commands — plus the hostAPI 2 typed routes and the
// `/sidecar/*` routes the tray and `ctl` use (ControlServer.swift).
//
// Same wire rules as Bromure AC's: HTTP/1.1, one request per connection,
// `Connection: close`, raw-DEFLATE bodies (Apple's .zlib) when the client
// sends X-Bromure-Gzip. Reached over SSH (`bromure-fatclient/1 control`)
// or locally.
package control

import (
	"bufio"
	"bytes"
	"compress/flate"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/paths"
)

// Request is one parsed request.
type Request struct {
	Method string
	Path   string // without the query
	Query  string
	Body   map[string]any
	Raw    []byte
	Gzip   bool
	conn   net.Conn
	rd     *bufio.Reader
	done   bool
}

// Conn is the connection, for routes that take it over (the PTY stream):
// reads go through the request's buffer, so bytes the client sent right
// after its body aren't lost.
func (r *Request) Conn() net.Conn {
	r.done = true
	return &bufConn{Conn: r.conn, rd: r.rd}
}

type bufConn struct {
	net.Conn
	rd *bufio.Reader
}

func (c *bufConn) Read(p []byte) (int, error) { return c.rd.Read(p) }

// CloseWrite half-closes a unix connection (the exit frame's EOF).
func (c *bufConn) CloseWrite() error {
	if cw, ok := c.Conn.(interface{ CloseWrite() error }); ok {
		return cw.CloseWrite()
	}
	return nil
}

// Response is a JSON (or raw) reply.
type Response struct {
	Status      int
	Body        any
	Raw         []byte
	ContentType string
}

// JSON is a JSON reply.
func JSON(status int, body any) Response { return Response{Status: status, Body: body} }

// Errorf is {"error": msg}.
func Errorf(status int, format string, a ...any) Response {
	return JSON(status, map[string]any{"error": fmt.Sprintf(format, a...)})
}

// Handler answers a request; a handler that took the connection over
// (Request.Conn) returns a zero Response.
type Handler func(*Request) Response

// Server is the control socket.
type Server struct {
	Route Handler
	l     net.Listener
	wg    sync.WaitGroup
}

const maxHeader = 1 << 20
const maxBody = 16 << 20

// Listen binds path (removing a stale socket) and serves until Close.
func (s *Server) Listen(path string) error {
	_ = os.Remove(path)
	l, err := net.Listen("unix", path)
	if err != nil {
		return err
	}
	_ = os.Chmod(path, 0o600)
	_ = paths.ProtectFile(path)
	s.l = l
	logx.Printf("control: listening on %s", path)
	go s.acceptLoop()
	return nil
}

// Serve serves an already-bound listener.
func (s *Server) Serve(l net.Listener) {
	s.l = l
	s.acceptLoop()
}

func (s *Server) acceptLoop() {
	for {
		c, err := s.l.Accept()
		if err != nil {
			if !strings.Contains(err.Error(), "closed") {
				logx.Printf("control: accept failed: %v", err)
			}
			return
		}
		s.wg.Add(1)
		go func() {
			defer s.wg.Done()
			s.handle(c)
		}()
	}
}

// Close stops listening.
func (s *Server) Close() error {
	if s.l != nil {
		return s.l.Close()
	}
	return nil
}

// ServeConn answers one request on an existing connection (the SSH
// `control` bridge can hand one straight in).
func (s *Server) ServeConn(c net.Conn) { s.handle(c) }

func (s *Server) handle(c net.Conn) {
	_ = c.SetReadDeadline(time.Now().Add(60 * time.Second))
	rd := bufio.NewReaderSize(c, 64<<10)
	// The header: up to the blank line.
	var head bytes.Buffer
	for {
		line, err := rd.ReadSlice('\n')
		head.Write(line)
		if err != nil && err != bufio.ErrBufferFull {
			c.Close()
			return
		}
		if head.Len() > maxHeader {
			c.Close()
			return
		}
		if bytes.HasSuffix(head.Bytes(), []byte("\r\n\r\n")) || bytes.Equal(head.Bytes(), []byte("\r\n")) {
			break
		}
		if bytes.HasSuffix(head.Bytes(), []byte("\n\n")) {
			break
		}
	}
	header := head.String()
	lower := strings.ToLower(header)
	contentLength := 0
	if i := strings.Index(lower, "content-length:"); i >= 0 {
		rest := strings.TrimLeft(lower[i+len("content-length:"):], " \t")
		j := 0
		for j < len(rest) && rest[j] >= '0' && rest[j] <= '9' {
			j++
		}
		contentLength, _ = strconv.Atoi(rest[:j])
	}
	if contentLength < 0 {
		contentLength = 0
	}
	if contentLength > maxBody {
		contentLength = maxBody
	}
	// The body: exactly Content-Length (a reader that waits for EOF
	// waited out every proxied call's socket timeout).
	body := make([]byte, contentLength)
	n, _ := io.ReadFull(rd, body)
	body = body[:n]
	_ = c.SetReadDeadline(time.Time{})
	first := strings.SplitN(header, "\r\n", 2)[0]
	parts := strings.SplitN(strings.TrimSpace(first), " ", 3)
	gzip := strings.Contains(lower, "x-bromure-gzip: 1")
	if len(parts) < 2 {
		writeResponse(c, Errorf(400, "Bad request"), false)
		c.Close()
		return
	}
	req := &Request{Method: parts[0], Path: parts[1], Raw: body, Gzip: gzip, conn: c, rd: rd, Body: map[string]any{}}
	if i := strings.IndexByte(req.Path, '?'); i >= 0 {
		req.Query = req.Path[i+1:]
		req.Path = req.Path[:i]
	}
	if len(body) > 0 {
		var m map[string]any
		if json.Unmarshal(body, &m) == nil && m != nil {
			req.Body = m
		}
	}
	resp := s.Route(req)
	if req.done {
		return // the route owns the connection now
	}
	writeResponse(c, resp, gzip)
	c.Close()
}

func statusText(s int) string {
	switch s {
	case 200:
		return "OK"
	case 400:
		return "Bad Request"
	case 404:
		return "Not Found"
	case 409:
		return "Conflict"
	case 501:
		return "Not Implemented"
	}
	if s < 400 {
		return "OK"
	}
	return "Error"
}

func writeResponse(w io.Writer, r Response, gzip bool) {
	data := r.Raw
	ctype := r.ContentType
	status := r.Status
	if status == 0 {
		status = 200
	}
	if data == nil {
		var err error
		data, err = json.Marshal(r.Body)
		if err != nil || len(data) == 0 {
			status = 500
			data = []byte(`{"error":"response serialization failed"}`)
		}
		ctype = "application/json"
	}
	if ctype == "" {
		ctype = "application/octet-stream"
	}
	extra := ""
	if gzip && len(data) > 1024 {
		var z bytes.Buffer
		fw, _ := flate.NewWriter(&z, flate.DefaultCompression)
		fw.Write(data)
		fw.Close()
		data = z.Bytes()
		extra = "X-Bromure-Gzip: 1\r\n"
	}
	head := fmt.Sprintf("HTTP/1.1 %d %s\r\nContent-Type: %s\r\n%sContent-Length: %d\r\nConnection: close\r\n\r\n",
		status, statusText(status), ctype, extra, len(data))
	bw := bufio.NewWriterSize(w, 64<<10)
	bw.WriteString(head)
	bw.Write(data)
	bw.Flush()
}
