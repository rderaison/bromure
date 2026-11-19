package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/agents"
	"github.com/rderaison/bromure/sidecar/internal/ctlclient"
	"github.com/rderaison/bromure/sidecar/internal/panes"
)

// ctlRoutes maps a ctl verb to its route. A verb starting with "/" is a
// path (GET without a body, POST with one); "GET /x" / "DELETE /x" name
// the method.
var ctlRoutes = map[string][2]string{
	"health":          {"GET", "/health"},
	"state":           {"GET", "/state"},
	"status":          {"GET", "/sidecar/status"},
	"signin":          {"POST", "/sidecar/signin"},
	"enroll":          {"POST", "/sidecar/enroll"},
	"enroll-callback": {"POST", "/sidecar/enroll"},
	"signout":         {"POST", "/sidecar/signout"},
	"servers":         {"GET", "/sidecar/servers"},
	"attach":          {"POST", "/sidecar/attach"},
	"detach":          {"POST", "/sidecar/detach"},
	"machine-name":    {"POST", "/sidecar/machine-name"},
	"agents/install":  {"POST", "/sidecar/agents/install"},
	"install-state":   {"GET", "/sidecar/install-state"},
	"approvals":       {"POST", "/sidecar/approvals"},
	"windows":         {"GET", "/sidecar/windows"},
	"start":           {"POST", "/agent-sessions/start"},
	"quit":            {"POST", "/sidecar/quit"},
}

func ctl(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: bromure-sidecar ctl <verb> [json]")
		names := []string{}
		for k := range ctlRoutes {
			names = append(names, k)
		}
		fmt.Fprintln(os.Stderr, "verbs: "+strings.Join(names, ", ")+", or a /path")
		return 2
	}
	verb := args[0]
	var body any
	if len(args) > 1 {
		raw := strings.Join(args[1:], " ")
		// `enroll <link>` and `machine-name <name>` take a bare word too.
		if !strings.HasPrefix(strings.TrimSpace(raw), "{") {
			switch verb {
			case "enroll", "enroll-callback":
				body = map[string]any{"link": raw}
			case "machine-name":
				body = map[string]any{"name": raw}
			default:
				fmt.Fprintln(os.Stderr, "ctl: the body must be a JSON object")
				return 2
			}
		} else {
			body = json.RawMessage(raw)
		}
	}
	method, path := "", ""
	if r, ok := ctlRoutes[verb]; ok {
		method, path = r[0], r[1]
	} else if strings.HasPrefix(verb, "/") {
		path = verb
		method = "GET"
		if body != nil {
			method = "POST"
		}
	} else if strings.Contains(verb, "/") && !strings.Contains(verb, " ") && !strings.Contains(verb, ":") {
		// A path without its leading slash (MSYS rewrites a leading one).
		path = "/" + verb
		method = "GET"
		if body != nil {
			method = "POST"
		}
	} else if i := strings.IndexByte(verb, ' '); i > 0 && strings.HasPrefix(verb[i+1:], "/") {
		method, path = verb[:i], verb[i+1:]
	} else {
		fmt.Fprintf(os.Stderr, "ctl: unknown verb %q\n", verb)
		return 2
	}
	if body == nil && method == "POST" {
		body = map[string]any{}
	}
	status, data, err := ctlclient.Do(method, path, body, 90*time.Second)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ctl: Bromure Sidecar isn't running (%v)\n", err)
		return 1
	}
	var v any
	if json.Unmarshal(data, &v) == nil {
		out, _ := json.MarshalIndent(v, "", "  ")
		fmt.Println(string(out))
	} else {
		os.Stdout.Write(data)
	}
	if status >= 400 {
		return 1
	}
	return 0
}

// runClaude is `bromure-sidecar claude [args…]`: start Claude in the
// current folder as a hosted session and attach this terminal to it.
// Detaching, or closing the terminal, leaves the agent running.
func runClaude(args []string) int {
	if !ensureDaemon() {
		fmt.Fprintln(os.Stderr, "bromure-claude: Bromure Sidecar isn't running and couldn't be started.")
		return 1
	}
	cwd, _ := os.Getwd()
	status, r, err := ctlclient.JSON("POST", "/agent-sessions/start", map[string]any{
		"tool": "claude", "cwd": cwd, "extraArgs": args}, 30*time.Second)
	w, ok := r["window"].(float64)
	if err != nil || status != 200 || !ok {
		msg, _ := r["error"].(string)
		if msg == "" && err != nil {
			msg = err.Error()
		}
		fmt.Fprintln(os.Stderr, "bromure-claude: couldn't start the session: "+msg)
		return 1
	}
	return panes.RunAttach(int(w), false)
}

// loginCheck is `__login <tool>`: a headless sign-in's link and code,
// then cancel (a check).
func loginCheck(tool string) int {
	agents.Panes = panes.EnsureHost
	st, err := agents.StartLogin(tool)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	for i := 0; i < 60; i++ {
		st = agents.LoginState(tool)
		if p, _ := st["phase"].(string); p != "starting" {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	out, _ := json.MarshalIndent(st, "", "  ")
	fmt.Println(string(out))
	agents.Cancel(tool, "")
	time.Sleep(time.Second)
	return 0
}
