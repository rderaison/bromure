// bromure-sidecar is Bromure Sidecar's console program: the daemon, the
// pane host, and the helpers agents and shells call.
//
//	serve                 the daemon (control.sock, SSH, P2P, machine links)
//	panehost              the long-lived pane host agents run in
//	attach <idx>          a terminal on a window (C-b d detaches)
//	ctl <verb> [json]     one control request, its JSON printed
//	claude [args…]        start Claude here as a hosted session and attach
//	__hook <state>        Claude Code's status hook
//	__mcp-delegation      the agents' delegation MCP server
//	__tmux / __ps         the tmux and ps shims (also as tmux[.exe] / ps[.exe])
//	version
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/rderaison/bromure/sidecar/internal/delegation"
	"github.com/rderaison/bromure/sidecar/internal/hooks"
	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/panes"
	"github.com/rderaison/bromure/sidecar/internal/shims"
)

// version is set by the build (-X main.version=…).
var version = "dev"

func main() { os.Exit(run(os.Args)) }

func run(args []string) int {
	invokedAs := strings.ToLower(strings.TrimSuffix(filepath.Base(args[0]), filepath.Ext(args[0])))
	switch invokedAs {
	case "tmux":
		return runTmux(args[1:])
	case "ps":
		return runPs(args[1:])
	case "python3", "python":
		logx.Quiet()
		return shims.RunPython(args[1:], os.Stdin, os.Stdout, os.Stderr)
	case "bromure-claude":
		return runClaude(args[1:])
	}
	if len(args) < 2 {
		usage()
		return 2
	}
	switch args[1] {
	case "serve":
		return serve(args[2:])
	case "panehost":
		return panes.RunHost()
	case "attach":
		if len(args) < 3 {
			fmt.Fprintln(os.Stderr, "usage: bromure-sidecar attach <window>")
			return 2
		}
		idx, err := strconv.Atoi(args[2])
		if err != nil {
			fmt.Fprintln(os.Stderr, "attach: window must be a number")
			return 2
		}
		passive := len(args) > 3 && args[3] == "--passive"
		return panes.RunAttach(idx, passive)
	case "ctl":
		return ctl(args[2:])

	// The command line that replaces the tray. Linux ships no GUI, so every
	// menu action has to be reachable over SSH; these wrap the same
	// control.sock routes the tray uses (see cli.go).
	case "status":
		return cliStatus()
	case "enroll", "pair":
		return cliEnroll(args[2:])
	case "signout":
		return cliSignout()
	case "servers":
		return cliServers()
	case "link":
		return cliLink(args[2:])
	case "unlink":
		return cliUnlink()
	case "sessions":
		return cliSessions()
	case "start":
		return cliStart(args[2:])
	case "stop":
		return cliStop(args[2:])
	case "agents":
		return cliAgents(args[2:])
	case "settings":
		return cliSettings(args[2:])
	case "logs":
		return cliLogs(args[2:])
	case "update":
		return cliUpdate(args[2:])
	case "shutdown":
		return cliShutdown()
	case "claude":
		return runClaude(args[2:])
	case "__hook":
		state := "done"
		if len(args) > 2 {
			state = args[2]
		}
		return hooks.Run(state, os.Stdin)
	case "__mcp-delegation":
		return delegation.RunShim()
	case "__tmux":
		return runTmux(args[2:])
	case "__ps":
		return runPs(args[2:])
	case "__login":
		if len(args) < 3 {
			return 2
		}
		return loginCheck(args[2])
	case "version", "--version", "-v":
		fmt.Println("bromure-sidecar " + version)
		return 0
	case "help", "--help", "-h":
		usage()
		return 0
	}
	usage()
	return 2
}

func usage() {
	fmt.Fprint(os.Stderr, `usage: bromure-sidecar <command>

this machine
  status              sign-in, serving, attach, agents, pane host
  sessions            the agent sessions running here
  start <tool> [dir]  start an agent session
  stop <window>       close one window
  attach <window>     a terminal on a window (C-b d detaches)
  claude [args…]      start Claude here as a hosted session and attach

the account
  enroll [link]       print the enroll URL, or finish it with the link
  signout             forget the account and detach
  servers             the account's Bromure AC servers
  link <server-id>    attach this machine to one
  unlink              detach

housekeeping
  agents [install T]  what is installed, and install one
  settings [k [v]]    read settings, or write one (v of - unsets)
  logs [-f] [-n N]    the daemon log
  update [--install]  check the release feed
  shutdown            stop the pane host and the daemon
  version

for scripts and the daemon
  serve               run the daemon
  panehost            run the pane host
  ctl <verb> [json]   one raw control request
`)
}

func runTmux(args []string) int {
	logx.Quiet()
	c, err := panes.Connect()
	if err != nil {
		// tmux's own words when there is no server.
		fmt.Fprintf(os.Stderr, "no server running on %s\n", "bromure")
		return 1
	}
	defer c.Close()
	return shims.RunTmux(c, args, os.Stdin, os.Stdout, os.Stderr)
}

func runPs(args []string) int {
	logx.Quiet()
	c, err := panes.Connect()
	if err != nil {
		return shims.RunPs(nil, args, os.Stdout, os.Stderr)
	}
	defer c.Close()
	return shims.RunPs(c, args, os.Stdout, os.Stderr)
}
