//go:build windows

package main

import (
	"embed"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"

	"github.com/rderaison/bromure/sidecar/internal/ctlclient"
	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/winutil"
)

// The UI is two WebView2 surfaces over native Windows 11 chrome:
//
//   - the flyout: a borderless, rounded, acrylic panel above the tray icon
//     (a left click), like Quick Settings — status, sessions, the account
//     and attach, a new session; it hides when it loses focus;
//   - the Agents window: a Mica window of agent cards (install, update,
//     sign in, approvals) — the macOS Sidecar's Manage Agents.
//
// Both draw with HTML/CSS (web/), the Mac Sidecar's own artwork (its mark
// and the agents' logos), and follow the Windows light/dark theme. Each
// runs on its own locked OS thread with its own message loop; the tray
// (systray) has the main thread.

//go:embed web
var webFS embed.FS

var (
	user32                  = windows.NewLazySystemDLL("user32.dll")
	dwmapi                  = windows.NewLazySystemDLL("dwmapi.dll")
	procSetWindowLongPtrW   = user32.NewProc("SetWindowLongPtrW")
	procGetWindowLongPtrW   = user32.NewProc("GetWindowLongPtrW")
	procSetWindowPos        = user32.NewProc("SetWindowPos")
	procShowWindow          = user32.NewProc("ShowWindow")
	procSetForegroundWindow = user32.NewProc("SetForegroundWindow")
	procGetForegroundWindow = user32.NewProc("GetForegroundWindow")
	procGetCursorPos        = user32.NewProc("GetCursorPos")
	procMonitorFromPoint    = user32.NewProc("MonitorFromPoint")
	procGetMonitorInfoW     = user32.NewProc("GetMonitorInfoW")
	procGetDpiForWindow     = user32.NewProc("GetDpiForWindow")
	procIsWindowVisible     = user32.NewProc("IsWindowVisible")
	procIsWindow            = user32.NewProc("IsWindow")
	procDwmSetWindowAttr    = dwmapi.NewProc("DwmSetWindowAttribute")
	procDwmExtendFrame      = dwmapi.NewProc("DwmExtendFrameIntoClientArea")
)

const (
	gwlStyle   = ^uintptr(15) // -16
	gwlExStyle = ^uintptr(19) // -20

	wsPopup        = 0x80000000
	wsThickFrame   = 0x00040000
	wsClipChildren = 0x02000000
	wsExToolWindow = 0x00000080
	wsExTopmost    = 0x00000008

	swpNoZOrder     = 0x0004
	swpNoActivate   = 0x0010
	swpFrameChanged = 0x0020
	swpShowWindow   = 0x0040
	hwndTopmost     = ^uintptr(0) // -1

	swHide = 0
	swShow = 5

	dwmaUseImmersiveDarkMode = 20
	dwmaWindowCornerPref     = 33
	dwmaBorderColor          = 34
	dwmaSystemBackdropType   = 38
	dwmwcpRound              = 2
	dwmsbtMainWindow         = 2 // Mica
	dwmsbtTransientWindow    = 3 // Acrylic (flyouts)
	dwmColorNone             = 0xFFFFFFFE
)

type point struct{ X, Y int32 }
type rect struct{ Left, Top, Right, Bottom int32 }
type monitorInfo struct {
	Size    uint32
	Monitor rect
	Work    rect
	Flags   uint32
}

func dwmSet(hwnd uintptr, attr uint32, v uint32) {
	procDwmSetWindowAttr.Call(hwnd, uintptr(attr), uintptr(unsafe.Pointer(&v)), 4)
}

// darkMode reads the apps' light/dark setting.
func darkMode() bool {
	k, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`, registry.QUERY_VALUE)
	if err != nil {
		return false
	}
	defer k.Close()
	v, _, err := k.GetIntegerValue("AppsUseLightTheme")
	return err == nil && v == 0
}

// taskbarDark reads the taskbar's (system) light/dark setting.
func taskbarDark() bool {
	k, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`, registry.QUERY_VALUE)
	if err != nil {
		return true
	}
	defer k.Close()
	v, _, err := k.GetIntegerValue("SystemUsesLightTheme")
	return err != nil || v == 0
}

// backdropSupported: Windows 11 22H2+ (build 22621) draws system backdrops.
func backdropSupported() bool {
	if os.Getenv("BROMURE_SIDECAR_NO_BACKDROP") == "1" {
		return false
	}
	return windows.RtlGetVersion().BuildNumber >= 22621
}

// applyChrome gives a window the Windows 11 look: rounded corners, the
// theme's dark frame, and (where supported) a system backdrop the
// transparent WebView shows through.
func applyChrome(hwnd uintptr, backdrop uint32) bool {
	dwmSet(hwnd, dwmaWindowCornerPref, dwmwcpRound)
	dark := uint32(0)
	if darkMode() {
		dark = 1
	}
	dwmSet(hwnd, dwmaUseImmersiveDarkMode, dark)
	if !backdropSupported() {
		return false
	}
	margins := [4]int32{-1, -1, -1, -1}
	procDwmExtendFrame.Call(hwnd, uintptr(unsafe.Pointer(&margins)))
	dwmSet(hwnd, dwmaSystemBackdropType, backdrop)
	return true
}

// --- the flyout -----------------------------------------------------------------

const flyoutW, flyoutH = 384, 600

var (
	surfMu    sync.Mutex
	flyout    *host
	agentsWin *host
)

// toggleFlyout shows the flyout above the tray (or hides it).
func toggleFlyout() {
	surfMu.Lock()
	h := flyout
	surfMu.Unlock()
	if h.alive() {
		if r, _, _ := procIsWindowVisible.Call(h.hwnd); r != 0 {
			hideFlyout()
			return
		}
		showFlyout()
		return
	}
	h, err := startHost(hostOptions{Title: "Bromure Sidecar", Width: flyoutW, Height: flyoutH,
		Popup: true, HideOnDeactivate: true, Backdrop: dwmsbtTransientWindow, Page: "flyout.html"}, bridge())
	if err != nil {
		logx.Printf("tray: flyout: %v", err)
		winutil.MessageBox(appName, err.Error(), winutil.MBOK|winutil.MBIconError)
		return
	}
	surfMu.Lock()
	flyout = h
	surfMu.Unlock()
	showFlyout()
}

func showFlyout() {
	surfMu.Lock()
	h := flyout
	surfMu.Unlock()
	if !h.alive() {
		return
	}
	h.dispatch(func() {
		x, y, w, hh := flyoutRect(h.hwnd)
		procSetWindowPos.Call(h.hwnd, hwndTopmost, uintptr(x), uintptr(y), uintptr(w), uintptr(hh), swpShowWindow)
		h.show(swShow)
		procSetForegroundWindow.Call(h.hwnd)
		h.chromium.Eval("window.sidecarShown && window.sidecarShown()")
	})
}

func hideFlyout() {
	surfMu.Lock()
	h := flyout
	surfMu.Unlock()
	if h.alive() {
		h.dispatch(h.hide)
	}
}

// flyoutRect anchors the flyout in the corner of the work area nearest the
// cursor (the tray icon was just clicked), 12 px in, sized for the DPI.
func flyoutRect(hwnd uintptr) (x, y, w, h int32) {
	var pt point
	procGetCursorPos.Call(uintptr(unsafe.Pointer(&pt)))
	mon, _, _ := procMonitorFromPoint.Call(uintptr(*(*uint64)(unsafe.Pointer(&pt))), 2)
	mi := monitorInfo{Size: uint32(unsafe.Sizeof(monitorInfo{}))}
	procGetMonitorInfoW.Call(mon, uintptr(unsafe.Pointer(&mi)))
	dpi, _, _ := procGetDpiForWindow.Call(hwnd)
	if dpi == 0 {
		dpi = 96
	}
	scale := float64(dpi) / 96
	w, h = int32(flyoutW*scale), int32(flyoutH*scale)
	gap := int32(12 * scale)
	wa := mi.Work
	if max := wa.Bottom - wa.Top - 2*gap; h > max {
		h = max
	}
	x = wa.Right - w - gap
	if pt.X < (wa.Left+wa.Right)/2 {
		x = wa.Left + gap
	}
	y = wa.Bottom - h - gap
	if pt.Y < (wa.Top+wa.Bottom)/2 {
		y = wa.Top + gap
	}
	return
}

var (
	holdMu    sync.Mutex
	holdUntil time.Time
)

// holdFlyout keeps the flyout up through a moment it loses focus on
// purpose (a message box, a terminal or the browser opening).
func holdFlyout(d time.Duration) {
	holdMu.Lock()
	holdUntil = time.Now().Add(d)
	holdMu.Unlock()
}

func suppressHide() bool {
	holdMu.Lock()
	defer holdMu.Unlock()
	return time.Now().Before(holdUntil)
}

// --- the Agents window -----------------------------------------------------------

func openAgents() {
	surfMu.Lock()
	h := agentsWin
	surfMu.Unlock()
	if h.alive() {
		h.dispatch(func() {
			h.show(9) // SW_RESTORE
			procSetForegroundWindow.Call(h.hwnd)
		})
		return
	}
	h, err := startHost(hostOptions{Title: "Coding Agents — Bromure Sidecar", Width: 820, Height: 720,
		MinW: 620, MinH: 520, Backdrop: dwmsbtMainWindow, Page: "agents.html"}, bridge())
	if err != nil {
		winutil.MessageBox(appName, err.Error(), winutil.MBOK|winutil.MBIconError)
		return
	}
	surfMu.Lock()
	agentsWin = h
	surfMu.Unlock()
	h.dispatch(func() {
		h.show(swShow)
		procSetForegroundWindow.Call(h.hwnd)
	})
}

// --- pages --------------------------------------------------------------------------

// renderPage inlines the shared stylesheet, the script and the artwork.
// previewScript, when set, runs after common.js (the --preview mode's mock bridge).
var previewScript string

func renderPage(name string) (string, error) {
	page, err := webFS.ReadFile("web/" + name)
	if err != nil {
		return "", err
	}
	css, _ := webFS.ReadFile("web/style.css")
	js, _ := webFS.ReadFile("web/common.js")
	svgs := map[string]string{}
	entries, _ := webFS.ReadDir("web/svg")
	for _, e := range entries {
		data, _ := webFS.ReadFile("web/svg/" + e.Name())
		svgs[strings.TrimSuffix(e.Name(), ".svg")] = string(data)
	}
	svgJSON, _ := json.Marshal(svgs)
	flags, _ := json.Marshal(map[string]any{"backdrop": backdropSupported(), "dark": darkMode(), "version": version})
	out := strings.Replace(string(page), "<!--STYLE-->", "<style>"+string(css)+"</style>", 1)
	out = strings.Replace(out, "<!--SCRIPT-->",
		"<script>window.SVG="+string(svgJSON)+";window.ENV="+string(flags)+";</script><script>"+string(js)+"</script>"+previewScript, 1)
	return out, nil
}

// --- the bridge ------------------------------------------------------------------

type handler = func(args []json.RawMessage) (any, error)

// bridge is what a page may call: control-socket requests and the few
// things only the shell can do.
func bridge() map[string]handler {
	return map[string]handler{
		// One control request: {status, body} (status 0: not running).
		"sidecarRequest": func(a []json.RawMessage) (any, error) {
			method, path := arg[string](a, 0), arg[string](a, 1)
			var body any
			if len(a) > 2 && string(a[2]) != "null" {
				body = json.RawMessage(a[2])
			}
			status, data, err := ctlclient.Do(method, path, body, 90*time.Second)
			if err != nil {
				return map[string]any{"status": 0, "error": "Bromure Sidecar isn't running"}, nil
			}
			var v any
			_ = json.Unmarshal(data, &v)
			return map[string]any{"status": status, "body": v}, nil
		},
		"sidecarOpenTerminal": func(a []json.RawMessage) (any, error) {
			holdFlyout(2 * time.Second)
			return nil, winutil.OpenTerminal(arg[string](a, 1), consoleExe(), "attach", fmt.Sprint(arg[int](a, 0)))
		},
		"sidecarOpenURL": func(a []json.RawMessage) (any, error) {
			u := arg[string](a, 0)
			if !strings.HasPrefix(u, "https://") {
				return nil, fmt.Errorf("only https links open")
			}
			holdFlyout(3 * time.Second)
			return nil, winutil.OpenURL(u)
		},
		"sidecarCopy":  func(a []json.RawMessage) (any, error) { return nil, winutil.SetClipboard(arg[string](a, 0)) },
		"sidecarPaste": func(a []json.RawMessage) (any, error) { return clipboardText(), nil },
		"sidecarOpenAgents": func(a []json.RawMessage) (any, error) {
			hideFlyout()
			go openAgents()
			return nil, nil
		},
		"sidecarPing": func(a []json.RawMessage) (any, error) {
			logx.Printf("ui: page says: %s", arg[string](a, 0))
			return nil, nil
		},
		"sidecarHide":         func(a []json.RawMessage) (any, error) { hideFlyout(); return nil, nil },
		"sidecarStartAtLogin": func(a []json.RawMessage) (any, error) { return winutil.StartsAtLogin("BromureSidecar"), nil },
		"sidecarSetStartAtLogin": func(a []json.RawMessage) (any, error) {
			self, _ := os.Executable()
			return nil, winutil.SetStartAtLogin("BromureSidecar", self, arg[bool](a, 0))
		},
		"sidecarInstallGit": func(a []json.RawMessage) (any, error) {
			holdFlyout(2 * time.Second)
			return nil, winutil.OpenTerminal("Install Git for Windows", "winget.exe", "install", "--id", "Git.Git", "-e", "--scope", "user")
		},
		"sidecarQuit": func(a []json.RawMessage) (any, error) {
			if n := arg[int](a, 0); n > 0 {
				holdFlyout(time.Minute)
				msg := fmt.Sprintf("%d agent(s) are running. They keep running after you quit, but Bromure AC can't reach them until Bromure Sidecar starts again. Quit?", n)
				ok := winutil.MessageBox(appName, msg, winutil.MBOKCancel|winutil.MBIconWarning) == winutil.IDOK
				holdFlyout(0)
				if !ok {
					return nil, nil
				}
			}
			ctlclient.Do("POST", "/sidecar/quit", map[string]any{}, 10*time.Second)
			quitTray()
			return nil, nil
		},
	}
}
