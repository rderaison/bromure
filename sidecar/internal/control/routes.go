package control

import (
	"encoding/base64"
	"encoding/json"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/hooks"
	"github.com/rderaison/bromure/sidecar/internal/hostexec"
	"github.com/rderaison/bromure/sidecar/internal/panes"
	"github.com/rderaison/bromure/sidecar/internal/sessions"
	"github.com/rderaison/bromure/sidecar/internal/settings"
	"github.com/rderaison/bromure/sidecar/internal/sysinfo"
	"github.com/rderaison/bromure/sidecar/internal/worktrees"
)

// HostAPI is the host contract version: 2 adds transcript-chunk, screen
// and per-tab agent{} (SIDECAR_WINDOWS_PLAN.md §5.6).
const HostAPI = 2

// Keys is the SSH server's authorized_keys management.
type Keys interface {
	AddAuthorizedKey(line string) error
	RemoveAuthorizedKey(selector string) error
}

// Sidecar answers the `/sidecar/<verb>` routes (account, attach, agents —
// wired by the daemon).
type Sidecar interface {
	Handle(verb string, body map[string]any) (int, map[string]any)
}

// API is every route.
type API struct {
	Engine  *sessions.Engine
	Keys    Keys
	Sidecar Sidecar
	// Panes connects a fresh pane host client (terminal attaches).
	Panes func() (panes.Client, error)

	gridMu sync.Mutex
	grid   []any
}

// MachineName is the user's choice, else the computer's name + "-native".
func MachineName() string {
	n := strings.TrimSpace(settings.String(settings.MachineName, ""))
	if n == "" {
		return sysinfo.DefaultMachineName()
	}
	return n
}

// SetMachineName saves a new name (trimmed, at most 60 characters; empty
// or the default clears it).
func SetMachineName(raw string) {
	name := strings.TrimSpace(raw)
	if r := []rune(name); len(r) > 60 {
		name = string(r[:60])
	}
	if name == "" || name == sysinfo.DefaultMachineName() {
		_ = settings.Remove(settings.MachineName)
	} else {
		_ = settings.Set(settings.MachineName, name)
	}
}

func idSegment(p, prefix, suffix string) string {
	s := strings.TrimSuffix(strings.TrimPrefix(p, prefix), suffix)
	if u, err := url.PathUnescape(s); err == nil {
		return u
	}
	return s
}

func sessErr(err error) Response {
	if se, ok := err.(*sessions.Error); ok {
		return Errorf(se.Status, "%s", se.Message)
	}
	return Errorf(500, "%v", err)
}

// Route dispatches one request.
func (a *API) Route(req *Request) Response {
	p, b := req.Path, req.Body
	e := a.Engine
	switch {
	case req.Method == "GET" && p == "/health":
		return JSON(200, map[string]any{"status": "ok", "service": "bromure-sidecar", "debugEnabled": false,
			"hostOS": sysinfo.HostOS(), "hostAPI": HostAPI})

	case req.Method == "GET" && p == "/state":
		return JSON(200, a.State())

	case req.Method == "GET" && p == "/vms":
		return JSON(200, map[string]any{"vms": []any{a.vmEntry(e.Snapshot())}})

	case req.Method == "GET" && p == "/grid-layout":
		a.gridMu.Lock()
		defer a.gridMu.Unlock()
		return JSON(200, map[string]any{"cells": a.cells()})

	case req.Method == "POST" && p == "/grid-layout":
		a.gridMu.Lock()
		a.grid, _ = b["cells"].([]any)
		a.gridMu.Unlock()
		return JSON(200, map[string]any{"ok": true})

	case req.Method == "POST" && p == "/remote/keys":
		key, _ := b["key"].(string)
		if a.Keys == nil {
			return Errorf(400, "remote access isn't running")
		}
		if err := a.Keys.AddAuthorizedKey(key); err != nil {
			return Errorf(400, "%s", err.Error())
		}
		return JSON(200, map[string]any{"ok": true})

	case req.Method == "DELETE" && strings.HasPrefix(p, "/remote/keys/"):
		sel := idSegment(p, "/remote/keys/", "")
		if a.Keys == nil {
			return Errorf(400, "remote access isn't running")
		}
		if err := a.Keys.RemoveAuthorizedKey(sel); err != nil {
			return Errorf(400, "%s", err.Error())
		}
		return JSON(200, map[string]any{"ok": true})

	case req.Method == "POST" && p == "/agent-sessions/start":
		tool, _ := b["tool"].(string)
		if tool == "" {
			tool = "claude"
		}
		cwd, _ := b["cwd"].(string)
		if cwd == "" {
			cwd = "~"
		}
		sr := sessions.StartRequest{Tool: tool, Cwd: cwd}
		sr.CloneURL, _ = b["cloneURL"].(string)
		sr.Message, _ = b["message"].(string)
		for _, x := range anyList(b["attachments"]) {
			if m, ok := x.(map[string]any); ok {
				sr.Attachments = append(sr.Attachments, m)
			}
		}
		for _, x := range anyList(b["extraArgs"]) {
			if s, ok := x.(string); ok {
				sr.ExtraArgs = append(sr.ExtraArgs, s)
			}
		}
		id, w, err := e.Start(sr)
		if err != nil {
			return sessErr(err)
		}
		return JSON(200, map[string]any{"ok": true, "id": id, "window": w})

	case req.Method == "POST" && p == "/agent-sessions/folders":
		path, _ := b["path"].(string)
		if path == "" {
			path = "~"
		}
		return JSON(200, map[string]any{"folders": sessions.Folders(path)})

	case req.Method == "GET" && strings.HasPrefix(p, "/agent-sessions/") && strings.HasSuffix(p, "/transcript"):
		id := sessions.ParseUUID(idSegment(p, "/agent-sessions/", "/transcript"))
		if id == "" {
			return Errorf(400, "Bad session id")
		}
		data, ok := e.Transcript(id)
		if !ok {
			return Errorf(404, "No transcript")
		}
		return JSON(200, map[string]any{"transcript": base64.StdEncoding.EncodeToString(data)})

	case req.Method == "POST" && p == "/agent-sessions/worktree-open":
		dir, _ := b["dir"].(string)
		branch, _ := b["branch"].(string)
		if dir == "" || branch == "" {
			return Errorf(400, "dir and branch required")
		}
		tool, _ := b["tool"].(string)
		if tool == "" {
			tool = "claude"
		}
		id, w, err := e.OpenBranch(dir, branch, str(b["parent"]), str(b["root"]), str(b["display"]), tool)
		if err != nil {
			return sessErr(err)
		}
		return JSON(200, map[string]any{"ok": true, "id": id, "window": w})

	case req.Method == "POST" && p == "/agent-sessions/worktree-discard":
		root, _ := b["root"].(string)
		branch, _ := b["branch"].(string)
		if root == "" || branch == "" {
			return Errorf(400, "root and branch required")
		}
		go e.DiscardWorktree(root, branch, str(b["session"]))
		return JSON(200, map[string]any{"ok": true})

	case req.Method == "POST" && p == "/agent-sessions/git-state":
		s, ok := e.Session(str(b["id"]))
		if !ok {
			return Errorf(404, "No such session")
		}
		return JSON(200, worktrees.FolderState(s.Cwd))

	case req.Method == "POST" && strings.HasPrefix(p, "/agent-sessions/"):
		parts := strings.SplitN(strings.TrimPrefix(p, "/agent-sessions/"), "/", 2)
		if len(parts) != 2 {
			return Errorf(404, "Not available on a native machine")
		}
		id := parts[0]
		if u, err := url.PathUnescape(id); err == nil {
			id = u
		}
		if sessions.ParseUUID(id) == "" {
			return Errorf(404, "Not available on a native machine")
		}
		out, err := e.Command(id, parts[1], b)
		if err != nil {
			return sessErr(err)
		}
		return JSON(200, out)

	case req.Method == "POST" && strings.HasPrefix(p, "/sessions/") && strings.HasSuffix(p, "/tab"):
		action, _ := b["action"].(string)
		idx, hasIdx := b["index"].(float64)
		switch action {
		case "select":
			if hasIdx {
				e.SelectWindow(int(idx))
			}
		case "close":
			if hasIdx {
				e.KillWindow(int(idx))
			}
		case "new":
			_ = e.NewShell()
		default:
			return Errorf(400, "action must be select, new or close")
		}
		return JSON(200, map[string]any{"ok": true})

	case req.Method == "POST" && strings.HasPrefix(p, "/vms/") && strings.HasSuffix(p, "/exec"):
		if v, _ := b["interactive"].(bool); v {
			hostexec.ServeInteractive(req.Conn(), b, a.Panes)
			return Response{}
		}
		r := hostexec.Run(b)
		return JSON(r.Status, r.Body)

	case req.Method == "POST" && strings.HasPrefix(p, "/vms/") && strings.HasSuffix(p, "/file"):
		op, _ := b["op"].(map[string]any)
		if op == nil {
			op = map[string]any{}
		}
		r := hostexec.FileOp(op)
		if _, bad := r["error"]; bad {
			return JSON(409, r)
		}
		return JSON(200, r)

	case req.Method == "POST" && strings.HasPrefix(p, "/vms/") && strings.HasSuffix(p, "/type"):
		text, okText := b["text"].(string)
		target, okTarget := sessions.ParsePaneTarget(b["target"])
		if !okText || !okTarget {
			return JSON(400, map[string]any{"typeRoute": true, "error": "target and text required"})
		}
		return JSON(200, map[string]any{"typeRoute": true, "output": e.TypeRoute(target, text)})

	case req.Method == "POST" && strings.HasPrefix(p, "/vms/") && strings.HasSuffix(p, "/transcript-chunk"):
		return Response{Status: 200, Raw: nonNil(e.TranscriptChunk(b)), ContentType: "application/octet-stream"}

	case req.Method == "POST" && strings.HasPrefix(p, "/vms/") && strings.HasSuffix(p, "/screen"):
		out, err := e.ScreenRoute(b)
		if err != nil {
			return sessErr(err)
		}
		return JSON(200, out)

	case req.Method == "POST" && p == "/sidecar/hook":
		var r hooks.Report
		if json.Unmarshal(req.Raw, &r) != nil {
			return Errorf(400, "bad hook report")
		}
		e.Hook(r)
		return JSON(200, map[string]any{"ok": true})

	case strings.HasPrefix(p, "/sidecar/"):
		if a.Sidecar == nil {
			return Errorf(404, "Not available")
		}
		status, out := a.Sidecar.Handle(strings.TrimPrefix(p, "/sidecar/"), b)
		return JSON(status, out)
	}
	return Errorf(404, "Not available on a native machine")
}

func nonNil(b []byte) []byte {
	if b == nil {
		return []byte{}
	}
	return b
}

func (a *API) cells() []any {
	if a.grid == nil {
		return []any{}
	}
	return a.grid
}

func anyList(v any) []any {
	l, _ := v.([]any)
	return l
}

func str(v any) string {
	s, _ := v.(string)
	return s
}

// --- /state ----------------------------------------------------------------

// State is the fat client's snapshot (ControlServer.stateSnapshot): one
// workspace (always running — a client ignores an empty list) whose VM
// entry carries the windows as tabs, plus the sessions; and the hostAPI 2
// fields.
func (a *API) State() map[string]any {
	snap := a.Engine.Snapshot()
	a.gridMu.Lock()
	cells := a.cells()
	a.gridMu.Unlock()
	st := map[string]any{
		"version":        1,
		"supportsPush":   false,
		"hostKind":       "agent-host",
		"hostOS":         sysinfo.HostOS(),
		"hostAPI":        HostAPI,
		"workspaces":     []any{a.workspaceEntry(snap)},
		"vms":            []any{a.vmEntry(snap)},
		"agentSessions":  nonNilSessions(snap.Sessions),
		"gridLayout":     map[string]any{"cells": cells},
		"automations":    map[string]any{"automations": []any{}, "runs": []any{}},
		"tasks":          map[string]any{"tasks": []any{}},
		"pendingPrompts": []any{},
		"subscriptions":  map[string]any{},
	}
	if hostexec.FindShell() == nil {
		st["shell"] = "missing"
	} else {
		st["shell"] = "ok"
	}
	return st
}

func nonNilSessions(s []sessions.Session) []sessions.Session {
	if s == nil {
		return []sessions.Session{}
	}
	return s
}

func state(snap sessions.Snapshot) string {
	if snap.PanesUp {
		return "running"
	}
	return "booting"
}

func (a *API) workspaceEntry(snap sessions.Snapshot) map[string]any {
	return map[string]any{
		"id": a.Engine.HostID, "name": MachineName(), "accentHex": "#5E8BDE", "color": "blue",
		"tool": "claude", "authMode": "subscription", "state": state(snap), "compromised": false,
		"memoryGB": sysinfo.MemoryGB(), "cpuCount": sysinfo.CPUCount(),
		"diskAllocatedBytes": 0, "diskCapacityBytes": 0, "hostKind": "agent-host",
	}
}

func (a *API) vmEntry(snap sessions.Snapshot) map[string]any {
	tabs := []any{}
	for _, w := range snap.Windows {
		t := map[string]any{"index": w.Index, "title": w.Title(), "active": w.Active, "cwd": w.Cwd}
		if w.Worktree != "" {
			t["isWorktree"] = true
			t["worktreeBranch"] = w.Worktree
			if w.ParentBranch != "" {
				t["parentBranch"] = w.ParentBranch
			}
			if w.RootRepo != "" {
				t["rootRepo"] = w.RootRepo
			}
		}
		if ag, ok := snap.Agents[w.Index]; ok {
			// A hook's last word; an agent that just started has none yet.
			status := "done"
			switch {
			case snap.Prompting[w.Index]:
				status = "needsInput"
			case w.Status == "working" || w.Status == "done" || w.Status == "needsInput":
				status = w.Status
			}
			t["agentStatus"] = status
			agent := map[string]any{"tool": ag.Tool, "pid": ag.PID, "startedAt": ag.StartedAt.Unix(), "alive": w.Alive}
			if w.ExitCode != nil {
				agent["exitCode"] = *w.ExitCode
			}
			t["agent"] = agent
		}
		tabs = append(tabs, t)
	}
	return map[string]any{
		"id": a.Engine.HostID, "name": MachineName(), "state": state(snap), "accentHex": "#5E8BDE",
		"kubeClusterID": "", "ip": "",
		// Monotonic, like a VM's: the machine's own uptime.
		"uptimeSeconds": int(sysinfo.Uptime() / time.Second),
		"bootedAt":      sysinfo.BootedAt(),
		"mounts":        []any{},
		"tabs":          tabs,
		"hostKind":      "agent-host",
		// What /home/ubuntu is here: virtual, as every path AC sees.
		"home": "/home/ubuntu",
	}
}
