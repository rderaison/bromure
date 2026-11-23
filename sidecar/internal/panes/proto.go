package panes

// The panes.sock protocol. Each connection carries JSON request lines, each
// answered by one JSON response line, in order:
//
//	→ {"op":"hello","version":1}
//	← {"ok":true,"result":{"version":1,"windows":3,"pid":1234}}
//	→ {"op":"capture","index":2,"capture":{"join":true}}
//	← {"ok":true,"result":"…"}
//	← {"ok":false,"error":"can't find window: 9","code":"nowindow"}
//
// "attach" switches its connection, after the OK response, to binary
// frames both ways: type (1 byte), length (uint32 big-endian), payload.
//
//	'd' data   host→client: output (repaint first); client→host: input
//	'r' resize client→host: cols, rows (uint32 BE each)
//	'x' exit   host→client: exit code (int32 BE); the host then closes
//
// The client detaches by closing the connection.

import (
	"bufio"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"sync"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/paths"
)

type request struct {
	Op            string            `json:"op"`
	Version       int               `json:"version,omitempty"`
	Index         int               `json:"index,omitempty"`
	IncludeHidden bool              `json:"includeHidden,omitempty"`
	Key           string            `json:"key,omitempty"`
	Value         string            `json:"value,omitempty"`
	Keys          []string          `json:"keys,omitempty"`
	Literal       bool              `json:"literal,omitempty"`
	Bracketed     bool              `json:"bracketed,omitempty"`
	Raw           bool              `json:"raw,omitempty"`
	Delete        bool              `json:"delete,omitempty"`
	Force         bool              `json:"force,omitempty"`
	Text          string            `json:"text,omitempty"`
	Name          string            `json:"name,omitempty"`
	Data          []byte            `json:"data,omitempty"`
	Cols          int               `json:"cols,omitempty"`
	Rows          int               `json:"rows,omitempty"`
	Passive       *bool             `json:"passive,omitempty"`
	ID            string            `json:"id,omitempty"`
	Session       string            `json:"session,omitempty"`
	NewWindow     *NewWindowRequest `json:"newWindow,omitempty"`
	Capture       *CaptureOptions   `json:"capture,omitempty"`
	Attach        *AttachRequest    `json:"attach,omitempty"`
}

type response struct {
	OK     bool            `json:"ok"`
	Error  string          `json:"error,omitempty"`
	Code   string          `json:"code,omitempty"`
	Result json.RawMessage `json:"result,omitempty"`
}

// HelloInfo is the handshake's answer.
type HelloInfo struct {
	Version int `json:"version"`
	Windows int `json:"windows"`
	PID     int `json:"pid"`
}

type optionResult struct {
	Value string `json:"value"`
	Set   bool   `json:"set"`
}

const maxLine = 64 << 20
const maxFrame = 1 << 20

var errCodes = []struct {
	code string
	err  error
}{
	{"nowindow", ErrNoWindow}, {"nobuffer", ErrNoBuffer}, {"noclient", ErrNoClient}, {"exited", ErrExited},
}

func errCode(err error) string {
	for _, c := range errCodes {
		if errors.Is(err, c.err) {
			return c.code
		}
	}
	return ""
}

// remoteErr rebuilds an error so errors.Is matches the host's sentinel.
type remoteErr struct {
	msg string
	is  error
}

func (e *remoteErr) Error() string { return e.msg }
func (e *remoteErr) Unwrap() error { return e.is }

func decodeErr(r *response) error {
	for _, c := range errCodes {
		if c.code == r.Code {
			return &remoteErr{msg: r.Error, is: c.err}
		}
	}
	return errors.New(r.Error)
}

// --- server ---

// Serve answers pane-host requests on l until l is closed (or a
// "shutdown" request closes it).
func Serve(l net.Listener, h *Host) error {
	for {
		c, err := l.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return nil
			}
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				time.Sleep(50 * time.Millisecond)
				continue
			}
			return err
		}
		go serveConn(c, h, l)
	}
}

func serveConn(c net.Conn, h *Host, l net.Listener) {
	defer c.Close()
	br := bufio.NewReaderSize(c, 64*1024)
	bw := bufio.NewWriter(c)
	for {
		line, err := readLine(br)
		if err != nil {
			return
		}
		var req request
		if err := json.Unmarshal(line, &req); err != nil {
			writeResp(bw, nil, fmt.Errorf("bad request: %v", err))
			continue
		}
		if req.Op == "attach" {
			serveAttach(c, br, bw, h, req)
			return
		}
		res, err := dispatch(h, &req)
		writeResp(bw, res, err)
		if req.Op == "shutdown" && err == nil {
			l.Close()
			return
		}
	}
}

func readLine(br *bufio.Reader) ([]byte, error) {
	var buf []byte
	for {
		chunk, err := br.ReadSlice('\n')
		buf = append(buf, chunk...)
		if err == nil {
			return buf, nil
		}
		if err != bufio.ErrBufferFull {
			return nil, err
		}
		if len(buf) > maxLine {
			return nil, fmt.Errorf("request too long")
		}
	}
}

func writeResp(bw *bufio.Writer, res any, err error) {
	r := response{OK: err == nil}
	if err != nil {
		r.Error = err.Error()
		r.Code = errCode(err)
	} else if res != nil {
		b, merr := json.Marshal(res)
		if merr != nil {
			r = response{Error: merr.Error()}
		} else {
			r.Result = b
		}
	}
	b, _ := json.Marshal(r)
	bw.Write(b)
	bw.WriteByte('\n')
	bw.Flush()
}

func dispatch(h *Host, r *request) (any, error) {
	switch r.Op {
	case "hello":
		return HelloInfo{Version: HostVersion, Windows: h.WindowCount(), PID: os.Getpid()}, nil
	case "shutdown":
		if n := h.WindowCount(); n > 0 && !r.Force {
			return nil, fmt.Errorf("pane host has %d windows", n)
		}
		return nil, nil
	case "new-window":
		if r.NewWindow == nil {
			return nil, fmt.Errorf("new-window: no request")
		}
		return h.NewWindow(*r.NewWindow)
	case "kill-window":
		return nil, h.KillWindow(r.Index)
	case "select-window":
		return nil, h.SelectWindow(r.Index)
	case "list":
		return h.List(r.IncludeHidden)
	case "get":
		return h.Get(r.Index)
	case "set-option":
		return nil, h.SetOption(r.Index, r.Key, r.Value)
	case "unset-option":
		return nil, h.UnsetOption(r.Index, r.Key)
	case "show-option":
		v, ok, err := h.ShowOption(r.Index, r.Key)
		return optionResult{v, ok}, err
	case "capture":
		var o CaptureOptions
		if r.Capture != nil {
			o = *r.Capture
		}
		return h.Capture(r.Index, o)
	case "screen":
		return h.Screen(r.Index)
	case "send-keys":
		return nil, h.SendKeys(r.Index, r.Keys, r.Literal)
	case "paste":
		return nil, h.Paste(r.Index, r.Text, r.Bracketed, r.Raw)
	case "resize-window":
		return nil, h.ResizeWindow(r.Index, r.Cols, r.Rows)
	case "list-clients":
		return h.ListClients()
	case "proc-table":
		return h.ProcTable()
	case "set-buffer":
		return nil, h.SetBuffer(r.Name, r.Data)
	case "paste-buffer":
		return nil, h.PasteBuffer(r.Name, r.Index, r.Bracketed, r.Raw, r.Delete)
	case "delete-buffer":
		return nil, h.DeleteBuffer(r.Name)
	case "refresh-client":
		return nil, h.RefreshClient(r.ID, r.Passive, r.Cols, r.Rows)
	case "detach-session":
		return h.DetachSession(r.Session)
	}
	return nil, fmt.Errorf("unknown op %q", r.Op)
}

func writeFrame(w io.Writer, typ byte, payload []byte) error {
	var hdr [5]byte
	hdr[0] = typ
	binary.BigEndian.PutUint32(hdr[1:], uint32(len(payload)))
	if _, err := w.Write(hdr[:]); err != nil {
		return err
	}
	_, err := w.Write(payload)
	return err
}

func readFrame(r io.Reader) (byte, []byte, error) {
	var hdr [5]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return 0, nil, err
	}
	n := binary.BigEndian.Uint32(hdr[1:])
	if n > maxFrame {
		return 0, nil, fmt.Errorf("frame too large (%d)", n)
	}
	p := make([]byte, n)
	if _, err := io.ReadFull(r, p); err != nil {
		return 0, nil, err
	}
	return hdr[0], p, nil
}

func serveAttach(c net.Conn, br *bufio.Reader, bw *bufio.Writer, h *Host, req request) {
	ar := AttachRequest{}
	if req.Attach != nil {
		ar = *req.Attach
	}
	att, err := h.AttachWith(ar)
	writeResp(bw, nil, err)
	if err != nil {
		return
	}
	defer att.Close()
	// Input and resizes from the client.
	go func() {
		for {
			typ, p, err := readFrame(br)
			if err != nil {
				att.Close()
				return
			}
			switch typ {
			case 'd':
				if _, err := att.Write(p); err != nil && !errors.Is(err, ErrExited) {
					att.Close()
					return
				}
			case 'r':
				if len(p) == 8 {
					att.Resize(int(binary.BigEndian.Uint32(p)), int(binary.BigEndian.Uint32(p[4:])))
				}
			}
		}
	}()
	var wmu sync.Mutex
	buf := make([]byte, 64*1024)
	for {
		n, err := att.Read(buf)
		if n > 0 {
			wmu.Lock()
			werr := writeFrame(c, 'd', buf[:n])
			wmu.Unlock()
			if werr != nil {
				return
			}
		}
		if err != nil {
			break
		}
	}
	select {
	case <-att.Exited():
		var p [4]byte
		binary.BigEndian.PutUint32(p[:], uint32(int32(att.ExitCode())))
		writeFrame(c, 'x', p[:])
	default:
		// Detached by the host (kill-session): no exit frame.
	}
}

// --- client ---

type remote struct {
	path string
	mu   sync.Mutex
	conn net.Conn
	br   *bufio.Reader
	info HelloInfo
}

var _ Client = (*remote)(nil)

// Connect opens a Client on the pane host's socket.
func Connect() (Client, error) { return Dial(paths.PanesSocket()) }

// Dial opens a Client on a pane host socket at path.
func Dial(path string) (Client, error) {
	r := &remote{path: path}
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.connectLocked(); err != nil {
		return nil, err
	}
	return r, nil
}

func (r *remote) connectLocked() error {
	c, err := net.DialTimeout("unix", r.path, 3*time.Second)
	if err != nil {
		return err
	}
	r.conn = c
	r.br = bufio.NewReaderSize(c, 64*1024)
	var hi HelloInfo
	if err := r.roundTripLocked(&request{Op: "hello", Version: HostVersion}, &hi); err != nil {
		c.Close()
		r.conn = nil
		return err
	}
	r.info = hi
	return nil
}

func (r *remote) roundTripLocked(req *request, out any) error {
	b, err := json.Marshal(req)
	if err != nil {
		return err
	}
	r.conn.SetDeadline(time.Now().Add(60 * time.Second))
	defer r.conn.SetDeadline(time.Time{})
	if _, err := r.conn.Write(append(b, '\n')); err != nil {
		return &connErr{err}
	}
	line, err := readLine(r.br)
	if err != nil {
		return &connErr{err}
	}
	var resp response
	if err := json.Unmarshal(line, &resp); err != nil {
		return &connErr{err}
	}
	if !resp.OK {
		return decodeErr(&resp)
	}
	if out != nil && len(resp.Result) > 0 {
		return json.Unmarshal(resp.Result, out)
	}
	return nil
}

// connErr is a transport failure (the connection is then dropped).
type connErr struct{ err error }

func (e *connErr) Error() string { return "pane host: " + e.err.Error() }
func (e *connErr) Unwrap() error { return e.err }

// readOnly ops are retried once on a fresh connection (a restarted host).
var readOnly = map[string]bool{
	"list": true, "get": true, "show-option": true, "capture": true, "screen": true,
	"list-clients": true, "proc-table": true,
}

func (r *remote) call(req *request, out any) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	for attempt := 0; ; attempt++ {
		if r.conn == nil {
			if err := r.connectLocked(); err != nil {
				return err
			}
		}
		err := r.roundTripLocked(req, out)
		var ce *connErr
		if err == nil || !errors.As(err, &ce) {
			return err
		}
		r.conn.Close()
		r.conn = nil
		if attempt > 0 || !readOnly[req.Op] {
			return err
		}
	}
}

func (r *remote) NewWindow(req NewWindowRequest) (Window, error) {
	var w Window
	err := r.call(&request{Op: "new-window", NewWindow: &req}, &w)
	return w, err
}
func (r *remote) KillWindow(index int) error {
	return r.call(&request{Op: "kill-window", Index: index}, nil)
}
func (r *remote) SelectWindow(index int) error {
	return r.call(&request{Op: "select-window", Index: index}, nil)
}
func (r *remote) List(includeHidden bool) ([]Window, error) {
	var ws []Window
	err := r.call(&request{Op: "list", IncludeHidden: includeHidden}, &ws)
	return ws, err
}
func (r *remote) Get(index int) (Window, error) {
	var w Window
	err := r.call(&request{Op: "get", Index: index}, &w)
	return w, err
}
func (r *remote) SetOption(index int, key, value string) error {
	return r.call(&request{Op: "set-option", Index: index, Key: key, Value: value}, nil)
}
func (r *remote) UnsetOption(index int, key string) error {
	return r.call(&request{Op: "unset-option", Index: index, Key: key}, nil)
}
func (r *remote) ShowOption(index int, key string) (string, bool, error) {
	var o optionResult
	err := r.call(&request{Op: "show-option", Index: index, Key: key}, &o)
	return o.Value, o.Set, err
}
func (r *remote) Capture(index int, opts CaptureOptions) (string, error) {
	var s string
	err := r.call(&request{Op: "capture", Index: index, Capture: &opts}, &s)
	return s, err
}
func (r *remote) Screen(index int) (Screen, error) {
	var s Screen
	err := r.call(&request{Op: "screen", Index: index}, &s)
	return s, err
}
func (r *remote) SendKeys(index int, keys []string, literal bool) error {
	return r.call(&request{Op: "send-keys", Index: index, Keys: keys, Literal: literal}, nil)
}
func (r *remote) Paste(index int, text string, bracketed, raw bool) error {
	return r.call(&request{Op: "paste", Index: index, Text: text, Bracketed: bracketed, Raw: raw}, nil)
}
func (r *remote) ResizeWindow(index int, cols, rows int) error {
	return r.call(&request{Op: "resize-window", Index: index, Cols: cols, Rows: rows}, nil)
}
func (r *remote) ListClients() ([]ClientInfo, error) {
	var cs []ClientInfo
	err := r.call(&request{Op: "list-clients"}, &cs)
	return cs, err
}
func (r *remote) ProcTable() ([]Proc, error) {
	var ps []Proc
	err := r.call(&request{Op: "proc-table"}, &ps)
	return ps, err
}
func (r *remote) SetBuffer(name string, data []byte) error {
	return r.call(&request{Op: "set-buffer", Name: name, Data: data}, nil)
}
func (r *remote) PasteBuffer(name string, index int, bracketed, raw, del bool) error {
	return r.call(&request{Op: "paste-buffer", Name: name, Index: index, Bracketed: bracketed, Raw: raw, Delete: del}, nil)
}
func (r *remote) DeleteBuffer(name string) error {
	return r.call(&request{Op: "delete-buffer", Name: name}, nil)
}
func (r *remote) RefreshClient(id string, passive *bool, cols, rows int) error {
	return r.call(&request{Op: "refresh-client", ID: id, Passive: passive, Cols: cols, Rows: rows}, nil)
}
func (r *remote) DetachSession(session string) (int, error) {
	var n int
	err := r.call(&request{Op: "detach-session", Session: session}, &n)
	return n, err
}
func (r *remote) Close() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.conn != nil {
		r.conn.Close()
		r.conn = nil
	}
	return nil
}

func (r *remote) Attach(index int, cols, rows int, passive bool) (Attachment, error) {
	return r.AttachWith(AttachRequest{Index: index, Cols: cols, Rows: rows, Passive: passive})
}

// AttachWith opens a dedicated connection for the stream.
func (r *remote) AttachWith(req AttachRequest) (Attachment, error) {
	c, err := net.DialTimeout("unix", r.path, 3*time.Second)
	if err != nil {
		return nil, err
	}
	br := bufio.NewReaderSize(c, 64*1024)
	b, _ := json.Marshal(&request{Op: "attach", Attach: &req})
	c.SetDeadline(time.Now().Add(30 * time.Second))
	if _, err := c.Write(append(b, '\n')); err != nil {
		c.Close()
		return nil, err
	}
	line, err := readLine(br)
	if err != nil {
		c.Close()
		return nil, err
	}
	c.SetDeadline(time.Time{})
	var resp response
	if err := json.Unmarshal(line, &resp); err != nil {
		c.Close()
		return nil, err
	}
	if !resp.OK {
		c.Close()
		return nil, decodeErr(&resp)
	}
	return &remoteAttachment{conn: c, br: br, exited: make(chan struct{})}, nil
}

type remoteAttachment struct {
	conn    net.Conn
	br      *bufio.Reader
	rmu     sync.Mutex
	pending []byte
	eof     bool
	wmu     sync.Mutex
	exited  chan struct{}
	exOnce  sync.Once
	code    int
	closeMu sync.Once
}

func (a *remoteAttachment) Read(p []byte) (int, error) {
	a.rmu.Lock()
	defer a.rmu.Unlock()
	for len(a.pending) == 0 {
		if a.eof {
			return 0, io.EOF
		}
		typ, payload, err := readFrame(a.br)
		if err != nil {
			a.eof = true
			return 0, io.EOF
		}
		switch typ {
		case 'd':
			a.pending = payload
		case 'x':
			if len(payload) == 4 {
				a.code = int(int32(binary.BigEndian.Uint32(payload)))
			}
			a.eof = true
			a.exOnce.Do(func() { close(a.exited) })
		}
	}
	n := copy(p, a.pending)
	a.pending = a.pending[n:]
	return n, nil
}

func (a *remoteAttachment) Write(p []byte) (int, error) {
	a.wmu.Lock()
	defer a.wmu.Unlock()
	for off := 0; off < len(p); off += maxFrame {
		end := off + maxFrame
		if end > len(p) {
			end = len(p)
		}
		if err := writeFrame(a.conn, 'd', p[off:end]); err != nil {
			return off, err
		}
	}
	return len(p), nil
}

func (a *remoteAttachment) Resize(cols, rows int) error {
	var p [8]byte
	binary.BigEndian.PutUint32(p[:], uint32(cols))
	binary.BigEndian.PutUint32(p[4:], uint32(rows))
	a.wmu.Lock()
	defer a.wmu.Unlock()
	return writeFrame(a.conn, 'r', p[:])
}

func (a *remoteAttachment) Exited() <-chan struct{} { return a.exited }

func (a *remoteAttachment) ExitCode() int {
	select {
	case <-a.exited:
		return a.code
	default:
		return 0
	}
}

func (a *remoteAttachment) Close() error {
	a.closeMu.Do(func() { a.conn.Close() })
	return nil
}
