package main

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/rderaison/bromure/sidecar/internal/updater"
	"os"
	"strings"
	"sync"

	"github.com/rderaison/bromure/sidecar/internal/agents"
	"github.com/rderaison/bromure/sidecar/internal/control"
	"github.com/rderaison/bromure/sidecar/internal/delegation"
	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/machinelink"
	"github.com/rderaison/bromure/sidecar/internal/panes"
	"github.com/rderaison/bromure/sidecar/internal/paths"
	"github.com/rderaison/bromure/sidecar/internal/sessions"
	"github.com/rderaison/bromure/sidecar/internal/settings"
	"github.com/rderaison/bromure/sidecar/internal/sshdial"
	"github.com/rderaison/bromure/sidecar/internal/sshserver"
)

// accountAPI is the bromure.io side (internal/account), behind what the
// verbs need.
type accountAPI interface {
	Status() map[string]any
	BeginSignIn() (string, error)
	Complete(raw string) error
	SignOut()
	Servers() []map[string]any
	RefreshServers()
	Stop()
}

// remote is everything that faces the network.
type remote struct {
	keys    control.Keys
	hub     *delegation.Hub
	ssh     *sshserver.Server
	sshErr  string
	linker  *machinelink.Linker
	account accountAPI
}

func (r *remote) stop() {
	if r.account != nil {
		r.account.Stop()
	}
	if r.linker != nil {
		r.linker.Detach(false)
	}
	if r.ssh != nil {
		r.ssh.Close()
	}
	if r.hub != nil {
		r.hub.Close()
	}
}

// keyFuncs is the package-level key management (works even when the SSH
// server didn't start).
type keyFuncs struct{}

func (keyFuncs) AddAuthorizedKey(l string) error    { return sshserver.AddAuthorizedKey(l) }
func (keyFuncs) RemoveAuthorizedKey(s string) error { return sshserver.RemoveAuthorizedKey(s) }

// UserName is the SSH login: the bare %USERNAME% (never DOMAIN\user).
func userName() string {
	for _, k := range []string{"USERNAME", "USER", "LOGNAME"} {
		if v := os.Getenv(k); v != "" {
			if i := strings.LastIndexAny(v, `\/`); i >= 0 {
				v = v[i+1:]
			}
			return v
		}
	}
	return "user"
}

func startRemote(engine *sessions.Engine, srv *control.Server) *remote {
	r := &remote{keys: keyFuncs{}}
	r.hub = delegation.NewHub("")
	if err := r.hub.Start(); err != nil {
		logx.Printf("serve: delegation: %v", err)
	}
	delegation.PaneWindow = paneWindow
	ssh, err := sshserver.Start(sshserver.Config{
		Port: settings.SSHPortValue(), User: userName(), ControlSocket: paths.ControlSocket(),
		Hub: r.hub, Panes: panes.Connect,
	})
	if err != nil {
		r.sshErr = err.Error()
		logx.Printf("serve: ssh: %v", err)
	} else {
		r.ssh = ssh
		logx.Printf("serve: ssh on %s", ssh.Addr())
	}
	r.account = startAccount(r)
	r.linker = machinelink.New(machinelink.Config{
		Dial:          accountDialer(r),
		MachineName:   control.MachineName,
		HostID:        func() string { return engine.HostID },
		ControlSocket: paths.ControlSocket(),
		Hub:           r.hub,
		ClosePeer: func(id string) {
			if theAccount != nil {
				theAccount.ClosePeer(id)
			}
		},
	})
	r.linker.Resume()
	return r
}

// paneWindow resolves a TMUX_PANE ("%N") to its window index.
func paneWindow(pane string) (int, error) {
	c, err := panes.Connect()
	if err != nil {
		return -1, err
	}
	defer c.Close()
	ws, err := c.List(true)
	if err != nil {
		return -1, err
	}
	for _, w := range ws {
		if w.PaneID == pane {
			return w.Index, nil
		}
	}
	return -1, os.ErrNotExist
}

// --- /sidecar/* --------------------------------------------------------------

type sidecarAPI struct {
	engine *sessions.Engine
	remote *remote
	mu     sync.Mutex
}

func errBody(msg string) map[string]any { return map[string]any{"error": msg} }

func (s *sidecarAPI) Handle(verb string, b map[string]any) (int, map[string]any) {
	r := s.remote
	switch verb {
	case "status":
		return 200, s.status()
	case "signin":
		if r.account == nil {
			return 501, errBody("accounts aren't available in this build")
		}
		u, err := r.account.BeginSignIn()
		if err != nil {
			return 400, errBody(err.Error())
		}
		return 200, map[string]any{"ok": true, "url": u}
	case "enroll":
		link, _ := b["link"].(string)
		if link == "" {
			link, _ = b["url"].(string)
		}
		if r.account == nil {
			return 501, errBody("accounts aren't available in this build")
		}
		if err := r.account.Complete(link); err != nil {
			return 400, errBody(err.Error())
		}
		return 200, map[string]any{"ok": true}
	case "signout":
		if r.account != nil {
			r.account.SignOut()
		}
		r.linker.Detach(true)
		return 200, map[string]any{"ok": true}
	case "servers":
		if r.account == nil {
			return 200, map[string]any{"servers": []any{}}
		}
		if refresh, _ := b["refresh"].(bool); refresh {
			r.account.RefreshServers()
		}
		return 200, map[string]any{"servers": r.account.Servers()}
	case "attach":
		id, _ := b["id"].(string)
		name, _ := b["name"].(string)
		user, _ := b["user"].(string)
		if id == "" {
			return 400, errBody("id required")
		}
		if name == "" || user == "" {
			for _, sv := range r.accountServers() {
				if sv["id"] == id {
					if name == "" {
						name, _ = sv["name"].(string)
					}
					if user == "" {
						user, _ = sv["user"].(string)
					}
				}
			}
		}
		r.linker.Attach(machinelink.Target{ID: id, Name: name, User: user})
		return 200, map[string]any{"ok": true}
	case "detach":
		forget := true
		if f, ok := b["forget"].(bool); ok {
			forget = f
		}
		r.linker.Detach(forget)
		return 200, map[string]any{"ok": true}
	case "machine-name":
		if n, ok := b["name"].(string); ok {
			control.SetMachineName(n)
		}
		return 200, map[string]any{"name": control.MachineName()}
	case "agents/install":
		ids := []string{}
		for _, x := range anyList(b["ids"]) {
			if s, ok := x.(string); ok {
				ids = append(ids, s)
			}
		}
		if id, ok := b["id"].(string); ok {
			ids = append(ids, id)
		}
		if err := agents.Install(ids); err != nil {
			return 400, errBody(err.Error())
		}
		return 200, map[string]any{"ok": true}
	case "install-state":
		if rescan, _ := b["rescan"].(bool); rescan {
			agents.Scan()
		}
		return 200, agents.InstallState()
	case "agents/signin":
		tool, _ := b["tool"].(string)
		st, err := agents.StartLogin(tool)
		if err != nil {
			return 400, errBody(err.Error())
		}
		return 200, st
	case "agents/signin-state":
		tool, _ := b["tool"].(string)
		return 200, agents.LoginState(tool)
	case "agents/signin-code":
		tool, _ := b["tool"].(string)
		code, _ := b["code"].(string)
		st, err := agents.SubmitCode(tool, code)
		if err != nil {
			return 400, errBody(err.Error())
		}
		return 200, st
	case "agents/log":
		tool, _ := b["tool"].(string)
		return 200, map[string]any{"tool": tool, "log": agents.Log(tool)}
	case "approvals":
		tool, _ := b["tool"].(string)
		level, _ := b["level"].(string)
		if level != "" {
			if err := sessions.SetApprovals(tool, level); err != nil {
				return 400, errBody(err.Error())
			}
		}
		out := map[string]any{}
		for _, t := range agents.Tools {
			out[t] = sessions.Approvals(t)
		}
		return 200, map[string]any{"approvals": out}
	case "windows":
		ws, err := s.engine.ListWindows()
		if err != nil {
			return 200, map[string]any{"windows": []any{}, "error": err.Error()}
		}
		list := []any{}
		snap := s.engine.Snapshot()
		for _, w := range ws {
			e := map[string]any{"index": w.Index, "title": w.Title(), "cwd": w.Cwd, "status": w.Status}
			if a, ok := snap.Agents[w.Index]; ok {
				e["agent"] = a.Tool
			}
			list = append(list, e)
		}
		return 200, map[string]any{"windows": list}
	case "new-session":
		tool, _ := b["tool"].(string)
		if tool == "" {
			tool = "claude"
		}
		cwd, _ := b["cwd"].(string)
		id, w, err := s.engine.Start(sessions.StartRequest{Tool: tool, Cwd: cwd})
		if err != nil {
			if se, ok := err.(*sessions.Error); ok {
				return se.Status, errBody(se.Message)
			}
			return 500, errBody(err.Error())
		}
		return 200, map[string]any{"ok": true, "id": id, "window": w}
	case "settings":
		// Read every setting, or write one. The daemon owns settings.json --
		// it caches it and several components read through that cache, so a
		// CLI that edited the file behind the daemon's back would be acted
		// on at an unpredictable moment, or not at all.
		if k, ok := b["key"].(string); ok && k != "" {
			if _, clear := b["unset"]; clear {
				if err := settings.Remove(k); err != nil {
					return 500, errBody(err.Error())
				}
			} else if err := settings.Set(k, b["value"]); err != nil {
				return 500, errBody(err.Error())
			}
		}
		out := map[string]any{}
		for k, v := range settings.All() {
			// The enroll nonce is a live handoff secret, not a setting
			// anybody should see in a listing.
			if k == settings.PendingEnroll {
				out[k] = "(hidden)"
				continue
			}
			var any_ any
			if json.Unmarshal(v, &any_) == nil {
				out[k] = any_
			} else {
				out[k] = string(v)
			}
		}
		return 200, map[string]any{"settings": out}
	case "panehost-stop":
		force, _ := b["force"].(bool)
		if err := panes.StopHost(force); err != nil {
			return 409, errBody(err.Error())
		}
		return 200, map[string]any{"ok": true}
	case "update-check":
		rel, err := updater.Check(context.Background(), version)
		if errors.Is(err, updater.ErrNoFeed) {
			// A state, not a failure: normal on Linux and macOS until their
			// feeds are published.
			return 200, map[string]any{"available": false, "version": version, "noFeed": true}
		}
		if err != nil {
			return 502, errBody(err.Error())
		}
		if rel == nil {
			return 200, map[string]any{"available": false, "version": version}
		}
		return 200, map[string]any{"available": true, "version": rel.Version}
	case "update-install":
		rel, err := updater.Check(context.Background(), version)
		if err != nil || rel == nil {
			return 409, errBody("no update available")
		}
		if err := updater.Install(context.Background(), rel); err != nil {
			return 502, errBody(err.Error())
		}
		return 200, map[string]any{"ok": true, "version": rel.Version}
	case "quit":
		select {
		case <-quit:
		default:
			close(quit)
		}
		return 200, map[string]any{"ok": true}
	}
	return 404, errBody("unknown sidecar verb " + verb)
}

func (r *remote) accountServers() []map[string]any {
	if r.account == nil {
		return nil
	}
	return r.account.Servers()
}

func (s *sidecarAPI) status() map[string]any {
	r := s.remote
	st := map[string]any{"version": version, "machineName": control.MachineName(), "user": userName()}
	if r.account != nil {
		st["account"] = r.account.Status()
	} else {
		st["account"] = map[string]any{"signedIn": false}
	}
	ls := r.linker.Status()
	st["attach"] = ls
	ssh := map[string]any{"port": settings.SSHPortValue()}
	if r.sshErr != "" {
		ssh["error"] = r.sshErr
	} else {
		ssh["fingerprint"] = sshserver.HostKeyFingerprint()
	}
	st["ssh"] = ssh
	if line, err := sshdial.ClientPublicKeyLine(); err == nil {
		st["clientKey"] = line
	}
	snap := s.engine.Snapshot()
	running := 0
	for range snap.Agents {
		running++
	}
	st["panesUp"] = snap.PanesUp
	st["agentsRunning"] = running
	st["windows"] = len(snap.Windows)
	return st
}

func anyList(v any) []any {
	l, _ := v.([]any)
	return l
}
