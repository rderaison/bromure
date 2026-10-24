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
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
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

const maxSlots = 12

type slots struct {
	parent *systray.MenuItem
	items  []*systray.MenuItem
	data   []map[string]any
}

func newSlots(parent *systray.MenuItem, n int, onClick func(map[string]any)) *slots {
	s := &slots{parent: parent, data: make([]map[string]any, n)}
	for i := 0; i < n; i++ {
		it := parent.AddSubMenuItem("", "")
		it.Hide()
		s.items = append(s.items, it)
		go func(i int) {
			for range it.ClickedCh {
				if d := s.data[i]; d != nil {
					go onClick(d)
				}
			}
		}(i)
	}
	return s
}

func (s *slots) set(rows []map[string]any, label func(map[string]any) string, empty string) {
	for i, it := range s.items {
		if i < len(rows) {
			s.data[i] = rows[i]
			it.SetTitle(label(rows[i]))
			it.Enable()
			it.Show()
		} else if i == 0 && len(rows) == 0 {
			s.data[i] = nil
			it.SetTitle(empty)
			it.Disable()
			it.Show()
		} else {
			s.data[i] = nil
			it.Hide()
		}
	}
}

type agentItems struct {
	head, install, signin *systray.MenuItem
}

var (
	mu        sync.Mutex
	lastAgent = map[string]map[string]any{}
)

func onReady() {
	systray.SetIcon(trayIcon(false, true))
	systray.SetTooltip(appName)

	header := systray.AddMenuItem("Starting…", "")
	header.Disable()
	detail := systray.AddMenuItem("", "")
	detail.Disable()
	detail.Hide()
	gitItem := systray.AddMenuItem("Install Git for Windows…", "Agents and Bromure AC's commands need Git Bash")
	gitItem.Hide()
	systray.AddSeparator()

	signIn := systray.AddMenuItem("Sign In to bromure.io…", "")
	pasteLink := systray.AddMenuItem("Paste a Sign-In Link…", "Use a bromure-agent-host:// link copied by hand")
	signOut := systray.AddMenuItem("Sign Out", "")
	attachMenu := systray.AddMenuItem("Attach to", "A Bromure AC server in your account")
	servers := newSlots(attachMenu, maxSlots, func(d map[string]any) {
		ctl("POST", "/sidecar/attach", map[string]any{"id": d["id"], "name": d["name"], "user": d["user"]})
	})
	detach := systray.AddMenuItem("Detach", "")
	systray.AddSeparator()

	termMenu := systray.AddMenuItem("Open Terminal", "A terminal on an agent's window")
	windows := newSlots(termMenu, maxSlots, func(d map[string]any) {
		idx := fmt.Sprint(d["index"])
		title, _ := d["title"].(string)
		if err := winutil.OpenTerminal(title, consoleExe(), "attach", idx); err != nil {
			winutil.MessageBox(appName, "Couldn't open a terminal: "+err.Error(), winutil.MBOK|winutil.MBIconError)
		}
	})
	newClaude := systray.AddMenuItem("New Claude Session in Home Folder", "")

	agentsMenu := systray.AddMenuItem("Agents", "")
	agentRows := map[string]*agentItems{}
	order := []string{"claude", "codex", "grok", "kimi", "omp"}
	names := map[string]string{"claude": "Claude Code", "codex": "Codex", "grok": "Grok Build", "kimi": "Kimi Code", "omp": "Oh My Pi"}
	for _, id := range order {
		head := agentsMenu.AddSubMenuItem(names[id], "")
		ai := &agentItems{head: head, install: head.AddSubMenuItem("Install", ""), signin: head.AddSubMenuItem("Sign In…", "")}
		agentRows[id] = ai
		go func(id string, ai *agentItems) {
			for {
				select {
				case <-ai.install.ClickedCh:
					if winutil.MessageBox(appName, "Install "+names[id]+" with its maker's installer, into your account?", winutil.MBOKCancel|winutil.MBIconInfo) == winutil.IDOK {
						if st, r := ctl("POST", "/sidecar/agents/install", map[string]any{"ids": []string{id}}); st != 200 {
							winutil.MessageBox(appName, fmt.Sprint(r["error"]), winutil.MBOK|winutil.MBIconError)
						}
					}
				case <-ai.signin.ClickedCh:
					go agentSignIn(id, names[id])
				}
			}
		}(id, ai)
	}
	systray.AddSeparator()
	startAtLogin := systray.AddMenuItemCheckbox("Start at Login", "", winutil.StartsAtLogin("BromureSidecar"))
	about := systray.AddMenuItem("About Bromure Sidecar", "")
	quitItem := systray.AddMenuItem("Quit Bromure Sidecar", "")

	refresh := func() {
		st, s := ctl("GET", "/sidecar/status", nil)
		if st != 200 {
			header.SetTitle("Bromure Sidecar isn't running")
			systray.SetIcon(trayIcon(false, true))
			return
		}
		acct, _ := s["account"].(map[string]any)
		signedIn, _ := acct["signedIn"].(bool)
		att, _ := s["attach"].(map[string]any)
		linked, _ := att["linked"].(bool)
		awaiting, _ := att["awaitingApproval"].(bool)
		tname := ""
		if t, ok := att["target"].(map[string]any); ok {
			tname, _ = t["name"].(string)
		}
		machine, _ := s["machineName"].(string)
		switch {
		case awaiting:
			header.SetTitle("Waiting for approval on " + tname)
		case linked:
			header.SetTitle("Attached to " + tname + " as " + machine)
		case tname != "":
			msg := "Connecting to " + tname + "…"
			if e, _ := att["error"].(string); e != "" {
				msg = tname + ": " + e
			}
			header.SetTitle(msg)
		case signedIn:
			header.SetTitle("Signed in as " + machine)
		default:
			header.SetTitle("Not signed in to bromure.io")
		}
		running, _ := s["agentsRunning"].(float64)
		if running > 0 {
			detail.SetTitle(fmt.Sprintf("%d agent(s) running", int(running)))
			detail.Show()
		} else {
			detail.Hide()
		}
		if signedIn {
			signIn.Hide()
			pasteLink.Hide()
			signOut.Show()
			attachMenu.Show()
		} else {
			signIn.Show()
			pasteLink.Show()
			signOut.Hide()
			attachMenu.Hide()
		}
		if tname != "" {
			detach.SetTitle("Detach from " + tname)
			detach.Show()
		} else {
			detach.Hide()
		}
		systray.SetIcon(trayIcon(false, !linked))
		// Windows.
		if _, w := ctl("GET", "/sidecar/windows", nil); w != nil {
			rows := toRows(w["windows"])
			windows.set(rows, func(d map[string]any) string {
				t, _ := d["title"].(string)
				return fmt.Sprintf("%v: %s", d["index"], t)
			}, "No windows")
		}
		if signedIn {
			_, sv := ctl("GET", "/sidecar/servers", nil)
			servers.set(toRows(sv["servers"]), func(d map[string]any) string { n, _ := d["name"].(string); return n }, "No servers online")
		}
		// Git Bash and agents.
		_, state := ctl("GET", "/state", nil)
		if sh, _ := state["shell"].(string); sh == "missing" {
			gitItem.Show()
		} else {
			gitItem.Hide()
		}
		_, inst := ctl("GET", "/sidecar/install-state", nil)
		for _, row := range toRows(inst["agents"]) {
			spec, _ := row["spec"].(map[string]any)
			ph, _ := row["phase"].(map[string]any)
			id, _ := spec["id"].(string)
			ai := agentRows[id]
			if ai == nil {
				continue
			}
			mu.Lock()
			lastAgent[id] = row
			mu.Unlock()
			state, _ := ph["state"].(string)
			label := names[id]
			ai.install.Show()
			ai.signin.Show()
			switch state {
			case "installed":
				v, _ := ph["version"].(string)
				label += " — Installed " + v
				ai.install.SetTitle("Update")
			case "installing", "queued":
				label += " — Installing…"
				ai.install.Disable()
			case "failed":
				label += " — Install failed"
				ai.install.SetTitle("Install")
				ai.install.Enable()
			case "unavailable":
				label += " — Not available on Windows yet"
				ai.install.Hide()
				ai.signin.Hide()
				ai.head.Disable()
			default:
				ai.install.SetTitle("Install")
				ai.install.Enable()
			}
			if id == "omp" {
				ai.signin.Hide()
			}
			ai.head.SetTitle(label)
		}
	}
	go func() {
		for {
			refresh()
			time.Sleep(4 * time.Second)
		}
	}()

	go func() {
		for {
			select {
			case <-signIn.ClickedCh:
				if st, r := ctl("POST", "/sidecar/signin", map[string]any{}); st != 200 {
					winutil.MessageBox(appName, fmt.Sprint(r["error"]), winutil.MBOK|winutil.MBIconError)
				}
			case <-pasteLink.ClickedCh:
				winutil.MessageBox(appName, "Copy the bromure-agent-host:// link, then press OK.", winutil.MBOK|winutil.MBIconInfo)
				if link := clipboardText(); link != "" {
					if st, r := ctl("POST", "/sidecar/enroll", map[string]any{"link": link}); st != 200 {
						winutil.MessageBox(appName, fmt.Sprint(r["error"]), winutil.MBOK|winutil.MBIconError)
					}
				}
			case <-signOut.ClickedCh:
				if winutil.MessageBox(appName, "Sign out of bromure.io? This machine detaches and stops serving.", winutil.MBOKCancel|winutil.MBIconWarning) == winutil.IDOK {
					ctl("POST", "/sidecar/signout", map[string]any{})
				}
			case <-detach.ClickedCh:
				ctl("POST", "/sidecar/detach", map[string]any{"forget": true})
			case <-newClaude.ClickedCh:
				if st, r := ctl("POST", "/sidecar/new-session", map[string]any{"tool": "claude", "cwd": "~"}); st != 200 {
					winutil.MessageBox(appName, fmt.Sprint(r["error"]), winutil.MBOK|winutil.MBIconError)
				} else if w, ok := r["window"].(float64); ok {
					_ = winutil.OpenTerminal("Claude", consoleExe(), "attach", fmt.Sprint(int(w)))
				}
			case <-gitItem.ClickedCh:
				_ = winutil.OpenTerminal("Install Git for Windows", "winget.exe", "install", "--id", "Git.Git", "-e", "--scope", "user")
			case <-startAtLogin.ClickedCh:
				self, _ := os.Executable()
				on := !startAtLogin.Checked()
				if err := winutil.SetStartAtLogin("BromureSidecar", self, on); err == nil {
					if on {
						startAtLogin.Check()
					} else {
						startAtLogin.Uncheck()
					}
				}
			case <-about.ClickedCh:
				_, s := ctl("GET", "/sidecar/status", nil)
				ssh, _ := s["ssh"].(map[string]any)
				fp, _ := ssh["fingerprint"].(string)
				winutil.MessageBox(appName, "Bromure Sidecar "+version+"\n\nRuns coding agents on this PC and shows them in Bromure AC.\n\nSSH host key: "+fp, winutil.MBOK|winutil.MBIconInfo)
			case <-quitItem.ClickedCh:
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
}

// agentSignIn runs an agent's headless sign-in and shows its link and
// code (copied to the clipboard).
func agentSignIn(id, name string) {
	st, r := ctl("POST", "/sidecar/agents/signin", map[string]any{"tool": id})
	if st != 200 {
		winutil.MessageBox(appName, fmt.Sprint(r["error"]), winutil.MBOK|winutil.MBIconError)
		return
	}
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		_, r = ctl("POST", "/sidecar/agents/signin-state", map[string]any{"tool": id})
		if p, _ := r["phase"].(string); p != "starting" {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	if p, _ := r["phase"].(string); p == "failed" {
		winutil.MessageBox(appName, name+": "+fmt.Sprint(r["message"]), winutil.MBOK|winutil.MBIconError)
		return
	}
	u, _ := r["url"].(string)
	code, _ := r["code"].(string)
	if u == "" {
		winutil.MessageBox(appName, name+": the sign-in didn't show a link yet. Try again.", winutil.MBOK|winutil.MBIconWarning)
		return
	}
	if code != "" {
		_ = winutil.SetClipboard(code)
		winutil.MessageBox(appName, "Sign in to "+name+":\n\n"+u+"\n\nYour code "+code+" is copied to the clipboard. Press OK to open the page.", winutil.MBOK|winutil.MBIconInfo)
		_ = winutil.OpenURL(u)
		return
	}
	_ = winutil.OpenURL(u)
	winutil.MessageBox(appName, "Sign in to "+name+" in your browser, then copy the code the page shows and press OK.", winutil.MBOK|winutil.MBIconInfo)
	if c := clipboardText(); c != "" {
		ctl("POST", "/sidecar/agents/signin-code", map[string]any{"tool": id, "code": c})
	}
}

func toRows(v any) []map[string]any {
	arr, _ := v.([]any)
	out := []map[string]any{}
	for _, x := range arr {
		if m, ok := x.(map[string]any); ok {
			out = append(out, m)
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		a, _ := out[i]["index"].(float64)
		b, _ := out[j]["index"].(float64)
		return a < b
	})
	return out
}

func clipboardText() string { return strings.TrimSpace(winutil.GetClipboard()) }
