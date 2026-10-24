//go:build windows

package main

import (
	"fmt"
	"image"
	"image/png"
	"os"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

// `BromureSidecar.exe --shot flyout|agents <file.png>`: open one surface,
// let it render, and save what is on screen in its rectangle (the system
// backdrop included) — for checking the UI and for the manual.

var (
	gdi32                      = windows.NewLazySystemDLL("gdi32.dll")
	procGetDC                  = user32.NewProc("GetDC")
	procReleaseDC              = user32.NewProc("ReleaseDC")
	procGetWindowRect          = user32.NewProc("GetWindowRect")
	procCreateCompatibleDC     = gdi32.NewProc("CreateCompatibleDC")
	procCreateCompatibleBitmap = gdi32.NewProc("CreateCompatibleBitmap")
	procSelectObject           = gdi32.NewProc("SelectObject")
	procBitBlt                 = gdi32.NewProc("BitBlt")
	procGetDIBits              = gdi32.NewProc("GetDIBits")
	procDeleteObject           = gdi32.NewProc("DeleteObject")
	procDeleteDC               = gdi32.NewProc("DeleteDC")
)

func runShot(which, out string) int {
	// A shot keeps the flyout up whatever has the focus.
	holdFlyout(time.Hour)
	var s *host
	switch which {
	case "flyout":
		toggleFlyout()
		s = flyout
	case "agents":
		openAgents()
		s = agentsWin
	default:
		fmt.Fprintln(os.Stderr, "usage: --shot flyout|agents <file.png>")
		return 2
	}
	if !s.alive() {
		return 1
	}
	time.Sleep(3500 * time.Millisecond)
	if s == flyout {
		showFlyout()
		time.Sleep(600 * time.Millisecond)
	}
	img, err := captureWindow(s.hwnd)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	f, err := os.Create(out)
	if err != nil {
		return 1
	}
	defer f.Close()
	png.Encode(f, img)
	return 0
}

type bitmapInfoHeader struct {
	Size          uint32
	Width         int32
	Height        int32
	Planes        uint16
	BitCount      uint16
	Compression   uint32
	SizeImage     uint32
	XPelsPerMeter int32
	YPelsPerMeter int32
	ClrUsed       uint32
	ClrImportant  uint32
}

// captureWindow copies the window's screen rectangle.
func captureWindow(hwnd uintptr) (*image.RGBA, error) {
	var r rect
	procGetWindowRect.Call(hwnd, uintptr(unsafe.Pointer(&r)))
	w, h := r.Right-r.Left, r.Bottom-r.Top
	if w <= 0 || h <= 0 {
		return nil, fmt.Errorf("window has no size")
	}
	screen, _, _ := procGetDC.Call(0)
	defer procReleaseDC.Call(0, screen)
	mem, _, _ := procCreateCompatibleDC.Call(screen)
	defer procDeleteDC.Call(mem)
	bmp, _, _ := procCreateCompatibleBitmap.Call(screen, uintptr(w), uintptr(h))
	defer procDeleteObject.Call(bmp)
	procSelectObject.Call(mem, bmp)
	const srccopy, captureblt = 0x00CC0020, 0x40000000
	procBitBlt.Call(mem, 0, 0, uintptr(w), uintptr(h), screen, uintptr(r.Left), uintptr(r.Top), srccopy|captureblt)
	bi := bitmapInfoHeader{Size: uint32(unsafe.Sizeof(bitmapInfoHeader{})), Width: w, Height: -h, Planes: 1, BitCount: 32}
	buf := make([]byte, int(w)*int(h)*4)
	procGetDIBits.Call(mem, bmp, 0, uintptr(h), uintptr(unsafe.Pointer(&buf[0])), uintptr(unsafe.Pointer(&bi)), 0)
	img := image.NewRGBA(image.Rect(0, 0, int(w), int(h)))
	for i := 0; i+3 < len(buf); i += 4 {
		img.Pix[i], img.Pix[i+1], img.Pix[i+2], img.Pix[i+3] = buf[i+2], buf[i+1], buf[i], 255
	}
	return img, nil
}

// `BromureSidecar.exe --preview flyout|agents <file.html>`: the page with
// demo data behind a mock bridge (no daemon, no window) — to check the
// layout in any browser and for the manual's screenshots.
func runPreview(which, out string) int {
	os.Setenv("BROMURE_SIDECAR_NO_BACKDROP", "1")
	previewScript = "<script>" + mockBridge + "</script>"
	html, err := renderPage(which + ".html")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	if err := os.WriteFile(out, []byte(html), 0o644); err != nil {
		return 1
	}
	return 0
}

const mockBridge = `(function(){
var now = Date.now()/1000;
var R = {
 "GET /sidecar/status": {machineName:"workstation-native", user:"you", version:"0.1.0", agentsRunning:2, panesUp:true,
   account:{signedIn:true, deviceName:"workstation-native", capability:"agent-host", serving:true},
   attach:{linked:true, awaitingApproval:false, target:{device:{id:"1", name:"studio", user:"you"}}},
   ssh:{port:2223, fingerprint:"256 SHA256:Ka/3kwiZGbXLyomRf1q13IU8gWSDNudusgyeiLgMi1U bromure-ac-remote (ED25519)"}},
 "GET /state": {shell:"ok", agentSessions:[{id:"A",windowIndex:0},{id:"B",windowIndex:1}],
   vms:[{tabs:[
     {index:0,title:"Refactor the payment retries",cwd:"/home/ubuntu/src/billing",agent:{tool:"claude",startedAt:now-1800},agentStatus:"working"},
     {index:1,title:"Fix flaky upload test",cwd:"/home/ubuntu/src/web",agent:{tool:"codex",startedAt:now-600},agentStatus:"needsInput"},
     {index:2,title:"Kimi in docs",cwd:"/home/ubuntu/src/docs",agent:{tool:"kimi",startedAt:now-300},agentStatus:"done"},
     {index:3,title:"shell",cwd:"/home/ubuntu"}]}]},
 "GET /sidecar/servers": {servers:[{id:"1",name:"studio",online:true}]},
 "GET /sidecar/install-state": {busy:false, agents:[
   {spec:{id:"claude",name:"Claude Code",maker:"Anthropic",blurb:"Anthropic's coding agent. Fully integrated: live status, chat, rooms and delegation.",install:"irm https://claude.ai/install.ps1 | iex",fullyIntegrated:true},phase:{state:"installed",version:"2.1.310"}},
   {spec:{id:"codex",name:"Codex",maker:"OpenAI",blurb:"OpenAI's coding agent for the terminal.",install:"irm https://chatgpt.com/codex/install.ps1 | iex"},phase:{state:"installing",line:"Downloading codex-x86_64-pc-windows-msvc.zip (38.2 MB)"}},
   {spec:{id:"grok",name:"Grok Build",maker:"xAI",blurb:"xAI's coding agent harness, a full-screen terminal UI.",install:"irm https://x.ai/cli/install.ps1 | iex"},phase:{state:"missing"}},
   {spec:{id:"kimi",name:"Kimi Code",maker:"Moonshot AI",blurb:"Moonshot's coding agent, a single binary (international edition).",install:"irm https://code.kimi.ai/kimi-code/install.ps1 | iex"},phase:{state:"installed",version:"2.3.1"}},
   {spec:{id:"omp",name:"Oh My Pi",maker:"Open source",blurb:"A terminal coding agent with an IDE's tools wired in.",install:"irm https://omp.sh/install.ps1 | iex"},phase:{state:"missing"}}]},
 "POST /sidecar/approvals": {approvals:{claude:"auto",codex:"ask",grok:"ask",kimi:"full",omp:"ask"}},
 "POST /agent-sessions/folders": {folders:["billing","docs","infra","web"]}
};
window.sidecarRequest = function(m,p,b){ var v = R[m+" "+p]; return Promise.resolve(v ? {status:200, body:JSON.parse(JSON.stringify(v))} : {status:200, body:{}}); };
["sidecarOpenTerminal","sidecarOpenURL","sidecarCopy","sidecarOpenAgents","sidecarHide","sidecarSetStartAtLogin","sidecarInstallGit","sidecarQuit"].forEach(function(n){ window[n]=function(){return Promise.resolve(null);}; });
window.sidecarPaste = function(){return Promise.resolve("");};
window.sidecarStartAtLogin = function(){return Promise.resolve(true);};
})();`
