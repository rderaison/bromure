//go:build windows

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"unsafe"

	"github.com/jchv/go-webview2/pkg/edge"
	"github.com/rderaison/bromure/sidecar/internal/logx"
	"golang.org/x/sys/windows"
)

// host is one native window holding a WebView2 controller, on its own
// UI thread: our window class and procedure (popup or framed, hidden until
// shown, hide-on-deactivate for the flyout), a transparent page background
// so the DWM backdrop shows through, and an asynchronous bridge — page
// calls run on goroutines and resolve back on the UI thread, so a slow
// control request never freezes the window.

var (
	procRegisterClassExW = user32.NewProc("RegisterClassExW")
	procCreateWindowExW  = user32.NewProc("CreateWindowExW")
	procDefWindowProcW   = user32.NewProc("DefWindowProcW")
	procDestroyWindow    = user32.NewProc("DestroyWindow")
	procGetMessageW      = user32.NewProc("GetMessageW")
	procTranslateMessage = user32.NewProc("TranslateMessage")
	procDispatchMessageW = user32.NewProc("DispatchMessageW")
	procPostQuitMessage  = user32.NewProc("PostQuitMessage")
	procPostThreadMsgW   = user32.NewProc("PostThreadMessageW")
	procSendMessageW     = user32.NewProc("SendMessageW")
	procLoadImageW       = user32.NewProc("LoadImageW")
	procGetSystemMetrics = user32.NewProc("GetSystemMetrics")
	kernel32             = windows.NewLazySystemDLL("kernel32.dll")
	procGetCurrentThread = kernel32.NewProc("GetCurrentThreadId")
	procCoInitializeEx   = windows.NewLazySystemDLL("ole32.dll").NewProc("CoInitializeEx")
)

const (
	wmDestroy       = 0x0002
	wmMove          = 0x0003
	wmSize          = 0x0005
	wmActivate      = 0x0006
	wmClose         = 0x0010
	wmGetMinMaxInfo = 0x0024
	wmSetIcon       = 0x0080
	wmSettingChange = 0x001A
	wmApp           = 0x8000
	waInactive      = 0

	wsOverlappedWindow = 0x00CF0000
	cwUseDefault       = 0x80000000
)

type wndClassEx struct {
	Size       uint32
	Style      uint32
	WndProc    uintptr
	ClsExtra   int32
	WndExtra   int32
	Instance   windows.Handle
	Icon       windows.Handle
	Cursor     windows.Handle
	Background windows.Handle
	MenuName   *uint16
	ClassName  *uint16
	IconSm     windows.Handle
}

type msg struct {
	Hwnd    uintptr
	Message uint32
	WParam  uintptr
	LParam  uintptr
	Time    uint32
	Pt      point
}

type minMaxInfo struct {
	Reserved, MaxSize, MaxPosition, MinTrackSize, MaxTrackSize point
}

// hostOptions shapes the window.
type hostOptions struct {
	Title            string
	Width, Height    int32 // logical pixels (scaled for the DPI)
	MinW, MinH       int32
	Popup            bool // borderless tool window (the flyout)
	HideOnDeactivate bool
	Backdrop         uint32 // DWMSBT_*
	Page             string
}

type host struct {
	opts     hostOptions
	hwnd     uintptr
	thread   uint32
	chromium *edge.Chromium
	scale    float64

	mu       sync.Mutex
	queue    []func()
	handlers map[string]func(args []json.RawMessage) (any, error)
	closed   chan struct{}
}

var (
	hostsMu    sync.Mutex
	hostsByWnd = map[uintptr]*host{}
	classOnce  sync.Once
	className  = windows.StringToUTF16Ptr("BromureSidecarWindow")
	hInstance  windows.Handle
)

func registerClass() {
	classOnce.Do(func() {
		_ = windows.GetModuleHandleEx(0, nil, &hInstance)
		wc := wndClassEx{
			Size:      uint32(unsafe.Sizeof(wndClassEx{})),
			WndProc:   windows.NewCallback(hostWndProc),
			Instance:  hInstance,
			ClassName: className,
		}
		// The exe's icon (resource 1, from tools/mkicons).
		wc.Icon = loadIcon(32)
		wc.IconSm = loadIcon(16)
		procRegisterClassExW.Call(uintptr(unsafe.Pointer(&wc)))
	})
}

func loadIcon(size int) windows.Handle {
	h, _, _ := procLoadImageW.Call(uintptr(hInstance), 1, 1 /* IMAGE_ICON */, uintptr(size), uintptr(size), 0)
	return windows.Handle(h)
}

func hostFor(hwnd uintptr) *host {
	hostsMu.Lock()
	defer hostsMu.Unlock()
	return hostsByWnd[hwnd]
}

func hostWndProc(hwnd, m, wp, lp uintptr) uintptr {
	h := hostFor(hwnd)
	if h != nil {
		switch uint32(m) {
		case wmSize:
			if h.chromium != nil {
				h.chromium.Resize()
			}
			return 0
		case wmMove:
			if h.chromium != nil {
				_ = h.chromium.NotifyParentWindowPositionChanged()
			}
		case wmActivate:
			if wp&0xFFFF == waInactive && h.opts.HideOnDeactivate && !suppressHide() {
				h.hide()
			} else if wp&0xFFFF != waInactive && h.chromium != nil {
				h.chromium.Focus()
			}
		case wmClose:
			if h.opts.Popup {
				h.hide()
				return 0
			}
			procDestroyWindow.Call(hwnd)
			return 0
		case wmDestroy:
			hostsMu.Lock()
			delete(hostsByWnd, hwnd)
			hostsMu.Unlock()
			procPostQuitMessage.Call(0)
			return 0
		case wmGetMinMaxInfo:
			if h.opts.MinW > 0 {
				mm := *(**minMaxInfo)(unsafe.Pointer(&lp))
				mm.MinTrackSize = point{int32(float64(h.opts.MinW) * h.scale), int32(float64(h.opts.MinH) * h.scale)}
			}
			return 0
		case wmSettingChange:
			// The light/dark setting changed: the frame follows (the page
			// follows on its own, through prefers-color-scheme).
			applyChrome(hwnd, h.opts.Backdrop)
		}
	}
	r, _, _ := procDefWindowProcW.Call(hwnd, m, wp, lp)
	return r
}

// newHost creates the window and its WebView on the calling thread (which
// must stay locked and then run h.loop).
func newHost(o hostOptions, handlers map[string]func(args []json.RawMessage) (any, error)) (*host, error) {
	registerClass()
	h := &host{opts: o, handlers: handlers, closed: make(chan struct{}), scale: 1}
	t, _, _ := procGetCurrentThread.Call()
	h.thread = uint32(t)
	style, ex := uintptr(wsOverlappedWindow), uintptr(0)
	if o.Popup {
		style, ex = wsPopup|wsClipChildren, wsExToolWindow|wsExTopmost
	}
	title, _ := windows.UTF16PtrFromString(o.Title)
	hwnd, _, err := procCreateWindowExW.Call(ex, uintptr(unsafe.Pointer(className)), uintptr(unsafe.Pointer(title)),
		style, cwUseDefault, cwUseDefault, uintptr(o.Width), uintptr(o.Height), 0, 0, uintptr(hInstance), 0)
	if hwnd == 0 {
		return nil, fmt.Errorf("CreateWindowEx: %v", err)
	}
	h.hwnd = hwnd
	hostsMu.Lock()
	hostsByWnd[hwnd] = h
	hostsMu.Unlock()
	if dpi, _, _ := procGetDpiForWindow.Call(hwnd); dpi != 0 {
		h.scale = float64(dpi) / 96
	}
	backdrop := applyChrome(hwnd, o.Backdrop)
	if o.Popup {
		dwmSet(hwnd, dwmaBorderColor, dwmColorNone)
	} else {
		// Centered on the primary screen, at the DPI's size.
		w, hh := int32(float64(o.Width)*h.scale), int32(float64(o.Height)*h.scale)
		sw, _, _ := procGetSystemMetrics.Call(0)
		sh, _, _ := procGetSystemMetrics.Call(1)
		procSetWindowPos.Call(hwnd, 0, uintptr((int32(sw)-w)/2), uintptr((int32(sh)-hh)/2), uintptr(w), uintptr(hh), swpNoZOrder|swpNoActivate)
		procSendMessageW.Call(hwnd, wmSetIcon, 0, uintptr(loadIcon(16)))
		procSendMessageW.Call(hwnd, wmSetIcon, 1, uintptr(loadIcon(32)))
	}

	c := edge.NewChromium()
	c.DataPath = filepath.Join(os.Getenv("LOCALAPPDATA"), "BromureSidecar", "webview")
	c.MessageCallback = h.onMessage
	c.SetPermission(edge.CoreWebView2PermissionKindClipboardRead, edge.CoreWebView2PermissionStateAllow)
	if !c.Embed(hwnd) {
		procDestroyWindow.Call(hwnd)
		return nil, fmt.Errorf("WebView2 isn't available (install the Microsoft Edge WebView2 Runtime)")
	}
	h.chromium = c
	logx.Printf("ui: %s: WebView2 embedded (hwnd %#x)", o.Page, hwnd)
	if s, err := c.GetSettings(); err == nil {
		_ = s.PutAreDefaultContextMenusEnabled(false)
		_ = s.PutAreDevToolsEnabled(os.Getenv("BROMURE_SIDECAR_DEVTOOLS") == "1")
	}
	if backdrop {
		// Fully transparent: the acrylic / Mica backdrop is the page's.
		if c2 := c.GetController().GetICoreWebView2Controller2(); c2 != nil {
			_ = c2.PutDefaultBackgroundColor(edge.COREWEBVIEW2_COLOR{A: 0, R: 0, G: 0, B: 0})
		}
	}
	c.Init(h.bridgeScript())
	html, err := renderPage(o.Page)
	if err != nil {
		return nil, err
	}
	c.NavigateToString(html)
	c.Resize()
	if b, err := c.GetController().GetBounds(); err == nil {
		logx.Printf("ui: %s: controller bounds %+v, backdrop %v, page %d bytes", o.Page, *b, backdrop, len(html))
	}
	return h, nil
}

// bridgeScript defines window.<name>(…args) → Promise for each handler.
func (h *host) bridgeScript() string {
	var names []string
	for n := range h.handlers {
		names = append(names, n)
	}
	sort.Strings(names)
	js, _ := json.Marshal(names)
	return `(function(){var pend={},seq=0;
window.__bromureResolve=function(id,ok,v){var p=pend[id];if(!p)return;delete pend[id];ok?p.res(v):p.rej(new Error(v));};
` + string(js) + `.forEach(function(n){window[n]=function(){var a=Array.prototype.slice.call(arguments);
return new Promise(function(res,rej){var id=++seq;pend[id]={res:res,rej:rej};
window.chrome.webview.postMessage(JSON.stringify({id:id,method:n,params:a}));});};});})();`
}

// onMessage is a page call: run it off the UI thread, answer on it.
func (h *host) onMessage(raw string) {
	var m struct {
		ID     int               `json:"id"`
		Method string            `json:"method"`
		Params []json.RawMessage `json:"params"`
	}
	if json.Unmarshal([]byte(raw), &m) != nil || m.ID == 0 {
		return // the echo of a message, or noise
	}
	f := h.handlers[m.Method]
	go func() {
		var out any
		var err error
		if f == nil {
			err = fmt.Errorf("no such call: %s", m.Method)
		} else {
			out, err = f(m.Params)
		}
		var js string
		if err != nil {
			e, _ := json.Marshal(err.Error())
			js = "window.__bromureResolve(" + strconv.Itoa(m.ID) + ",false," + string(e) + ")"
		} else {
			v, jerr := json.Marshal(out)
			if jerr != nil {
				v = []byte("null")
			}
			js = "window.__bromureResolve(" + strconv.Itoa(m.ID) + ",true," + string(v) + ")"
		}
		h.dispatch(func() { h.chromium.Eval(js) })
	}()
}

// dispatch runs f on the window's UI thread.
func (h *host) dispatch(f func()) {
	h.mu.Lock()
	h.queue = append(h.queue, f)
	h.mu.Unlock()
	procPostThreadMsgW.Call(uintptr(h.thread), wmApp, 0, 0)
}

// loop pumps messages until the window is destroyed.
func (h *host) loop() {
	var m msg
	for {
		r, _, _ := procGetMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if int32(r) <= 0 {
			break
		}
		if m.Message == wmApp && m.Hwnd == 0 {
			h.mu.Lock()
			q := h.queue
			h.queue = nil
			h.mu.Unlock()
			for _, f := range q {
				f()
			}
			continue
		}
		procTranslateMessage.Call(uintptr(unsafe.Pointer(&m)))
		procDispatchMessageW.Call(uintptr(unsafe.Pointer(&m)))
	}
	close(h.closed)
}

// startHost runs a host on its own locked thread; nil and an error when
// it couldn't be created.
func startHost(o hostOptions, handlers map[string]func(args []json.RawMessage) (any, error)) (*host, error) {
	type result struct {
		h   *host
		err error
	}
	ready := make(chan result, 1)
	go func() {
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
		// WebView2 needs a single-threaded COM apartment on its UI thread
		// (the library initialises COM only on the thread its init ran on).
		procCoInitializeEx.Call(0, 2 /* COINIT_APARTMENTTHREADED */)
		h, err := newHost(o, handlers)
		ready <- result{h, err}
		if err == nil {
			h.loop()
		}
	}()
	r := <-ready
	return r.h, r.err
}

func (h *host) alive() bool {
	if h == nil {
		return false
	}
	select {
	case <-h.closed:
		return false
	default:
	}
	r, _, _ := procIsWindow.Call(h.hwnd)
	return r != 0
}

// arg decodes the i-th call argument.
func arg[T any](args []json.RawMessage, i int) T {
	var v T
	if i < len(args) {
		_ = json.Unmarshal(args[i], &v)
	}
	return v
}

var _ = strings.TrimSpace

// show makes the window and its WebView visible (UI thread). A controller
// created in a hidden window doesn't draw until told it's visible, with
// bounds from the window as it is now.
func (h *host) show(cmd uintptr) {
	procShowWindow.Call(h.hwnd, cmd)
	if h.chromium != nil {
		_ = h.chromium.Show()
		h.chromium.Resize()
	}
}

// hide hides the window; its WebView stops rendering meanwhile (UI thread).
func (h *host) hide() {
	if h.chromium != nil {
		_ = h.chromium.Hide()
	}
	procShowWindow.Call(h.hwnd, swHide)
}
