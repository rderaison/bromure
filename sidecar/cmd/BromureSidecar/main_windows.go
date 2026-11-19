//go:build windows

// BromureSidecar is the tray app (GUI subsystem: build with -H windowsgui).
// It starts the daemon, shows its status, signs in, attaches, installs
// agents and opens terminals — all through `bromure-sidecar ctl`'s
// control.sock routes. Quitting the tray stops the daemon only; agents keep
// running in the pane host.
//
//	BromureSidecar.exe                       the tray (single instance)
//	BromureSidecar.exe bromure-agent-host://… hand an enrollment link to the daemon
package main

import (
	_ "embed"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"fyne.io/systray"

	"github.com/rderaison/bromure/sidecar/internal/ctlclient"
	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/winutil"
)

var version = "dev"

const appName = "Bromure Sidecar"
const urlScheme = "bromure-agent-host"

// consoleExe is bromure-sidecar.exe beside this binary.
func consoleExe() string {
	self, _ := os.Executable()
	return filepath.Join(filepath.Dir(self), "bromure-sidecar.exe")
}

func main() {
	logx.Quiet()
	if len(os.Args) > 1 && strings.HasPrefix(strings.ToLower(os.Args[1]), urlScheme+":") {
		os.Exit(forwardURL(os.Args[1]))
	}
	if len(os.Args) > 3 && os.Args[1] == "--preview" {
		os.Exit(runPreview(os.Args[2], os.Args[3]))
	}
	if len(os.Args) > 3 && os.Args[1] == "--shot" {
		os.Exit(runShot(os.Args[2], os.Args[3]))
	}
	if !winutil.SingleInstance("BromureSidecarTray") {
		return
	}
	self, _ := os.Executable()
	if err := winutil.RegisterURLScheme(urlScheme, self, appName); err != nil {
		logx.Printf("tray: URL scheme: %v", err)
	}
	firstRun := !fileExists(filepath.Join(os.Getenv("LOCALAPPDATA"), "BromureSidecar", "settings.json"))
	if firstRun && !winutil.StartsAtLogin("BromureSidecar") {
		_ = winutil.SetStartAtLogin("BromureSidecar", self, true)
	}
	ensureDaemon()
	systray.Run(onReady, func() {})
}

func fileExists(p string) bool { _, err := os.Stat(p); return err == nil }

// forwardURL hands an enrollment link to the running daemon (starting it
// first if needed) and exits: the second instance a browser launches.
func forwardURL(u string) int {
	ensureDaemon()
	status, r, err := ctlclient.JSON("POST", "/sidecar/enroll", map[string]any{"link": u}, 60*time.Second)
	if err != nil || status != 200 {
		msg := "The sign-in link couldn't be used."
		if e, _ := r["error"].(string); e != "" {
			msg = e
		} else if err != nil {
			msg = "Bromure Sidecar isn't running: " + err.Error()
		}
		winutil.MessageBox(appName, msg, winutil.MBOK|winutil.MBIconError)
		return 1
	}
	return 0
}

func ensureDaemon() bool {
	if ctlclient.Healthy() {
		return true
	}
	cmd := exec.Command(consoleExe(), "serve")
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000 | 0x00000200}
	if err := cmd.Start(); err != nil {
		winutil.MessageBox(appName, "Couldn't start bromure-sidecar.exe: "+err.Error(), winutil.MBOK|winutil.MBIconError)
		return false
	}
	_ = cmd.Process.Release()
	for i := 0; i < 50; i++ {
		if ctlclient.Healthy() {
			return true
		}
		time.Sleep(200 * time.Millisecond)
	}
	return false
}

func ctl(method, path string, body any) (int, map[string]any) {
	status, r, err := ctlclient.JSON(method, path, body, 60*time.Second)
	if err != nil {
		return 0, map[string]any{"error": err.Error()}
	}
	return status, r
}

// --- the menu -----------------------------------------------------------------

// --- the tray ------------------------------------------------------------------

//go:embed assets/tray.ico
var icoTray []byte

//go:embed assets/tray-badge.ico
var icoTrayBadge []byte

//go:embed assets/tray-idle.ico
var icoTrayIdle []byte

//go:embed assets/tray-dark.ico
var icoTrayDark []byte

//go:embed assets/tray-dark-badge.ico
var icoTrayDarkBadge []byte

//go:embed assets/tray-dark-idle.ico
var icoTrayDarkIdle []byte

// trayState is what the icon shows: idle (not attached / not running),
// linked, or an agent needing the user (badge).
type trayState int

const (
	trayIdle trayState = iota
	trayLinked
	trayBadge
)

func iconFor(s trayState) []byte {
	dark := taskbarDark()
	switch {
	case s == trayBadge && dark:
		return icoTrayDarkBadge
	case s == trayBadge:
		return icoTrayBadge
	case s == trayLinked && dark:
		return icoTrayDark
	case s == trayLinked:
		return icoTray
	case dark:
		return icoTrayDarkIdle
	}
	return icoTrayIdle
}

func quitTray() { systray.Quit() }

func onReady() {
	systray.SetIcon(iconFor(trayIdle))
	systray.SetTooltip(appName)
	// A left click: the flyout. A right click: this small menu.
	systray.SetOnTapped(func() { go toggleFlyout() })
	open := systray.AddMenuItem("Open Bromure Sidecar", "")
	agents := systray.AddMenuItem("Coding Agents…", "")
	systray.AddSeparator()
	quit := systray.AddMenuItem("Quit Bromure Sidecar", "")
	go func() {
		for {
			select {
			case <-open.ClickedCh:
				go toggleFlyout()
			case <-agents.ClickedCh:
				go openAgents()
			case <-quit.ClickedCh:
				_, s := ctl("GET", "/sidecar/status", nil)
				if n, _ := s["agentsRunning"].(float64); n > 0 {
					msg := fmt.Sprintf("%d agent(s) are running. They keep running after you quit, but Bromure AC can't reach them until Bromure Sidecar starts again. Quit?", int(n))
					if winutil.MessageBox(appName, msg, winutil.MBOKCancel|winutil.MBIconWarning) != winutil.IDOK {
						continue
					}
				}
				ctl("POST", "/sidecar/quit", map[string]any{})
				systray.Quit()
				return
			}
		}
	}()
	// The icon and tooltip follow the state (and the taskbar's theme).
	go func() {
		last := ""
		for {
			state, tip := trayIdle, appName+" — not running"
			if st, s := ctl("GET", "/sidecar/status", nil); st == 200 {
				tip = appName
				att, _ := s["attach"].(map[string]any)
				if linked, _ := att["linked"].(bool); linked {
					state = trayLinked
					if t, ok := att["target"].(map[string]any); ok {
						if d, ok := t["device"].(map[string]any); ok {
							t = d
						}
						tip += " — attached to " + fmt.Sprint(t["name"])
					}
				}
				if _, st := ctl("GET", "/state", nil); st != nil {
					if needsUser(st) {
						state = trayBadge
						tip += " — an agent needs you"
					}
				}
			}
			key := fmt.Sprint(state, taskbarDark(), tip)
			if key != last {
				systray.SetIcon(iconFor(state))
				systray.SetTooltip(tip)
				last = key
			}
			time.Sleep(4 * time.Second)
		}
	}()
}

// needsUser: a tab whose agent waits on the user.
func needsUser(state map[string]any) bool {
	vms, _ := state["vms"].([]any)
	for _, v := range vms {
		vm, _ := v.(map[string]any)
		tabs, _ := vm["tabs"].([]any)
		for _, t := range tabs {
			tab, _ := t.(map[string]any)
			if tab["agentStatus"] == "needsInput" {
				return true
			}
		}
	}
	return false
}

func clipboardText() string { return strings.TrimSpace(winutil.GetClipboard()) }
