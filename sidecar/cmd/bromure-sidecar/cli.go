package main

// The command-line surface. On Linux there is no tray, so every action the
// macOS/Windows menu offers has to be reachable from a shell over SSH: sign
// in, attach to a server, list and start sessions, install agents, read
// settings and logs, check for updates, stop everything.
//
// These are thin wrappers over the same control.sock routes the tray uses,
// with human output. `ctl` stays the raw escape hatch for scripts and is
// what these call underneath, so there is one implementation of each action
// rather than two.

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/ctlclient"
	"github.com/rderaison/bromure/sidecar/internal/paths"
)

const cliTimeout = 90 * time.Second

// req is one control request; it reports the daemon being down as such,
// because "connection refused" on a unix socket is not a useful sentence.
func req(method, path string, body any) (map[string]any, error) {
	status, out, err := ctlclient.JSON(method, path, body, cliTimeout)
	if err != nil {
		return nil, fmt.Errorf("Bromure Sidecar isn't running: %v\n"+
			"  start it with: systemctl --user start bromure-sidecar", err)
	}
	if status >= 400 {
		msg, _ := out["error"].(string)
		if msg == "" {
			msg = fmt.Sprintf("HTTP %d", status)
		}
		return out, fmt.Errorf("%s", msg)
	}
	return out, nil
}

func cliFail(err error) int {
	fmt.Fprintln(os.Stderr, err.Error())
	return 1
}

func str(m map[string]any, k string) string { s, _ := m[k].(string); return s }
func bul(m map[string]any, k string) bool   { b, _ := m[k].(bool); return b }

func obj(m map[string]any, k string) map[string]any {
	o, _ := m[k].(map[string]any)
	return o
}

func sliceOf(m map[string]any, k string) []string {
	raw, _ := m[k].([]any)
	out := make([]string, 0, len(raw))
	for _, v := range raw {
		if s, ok := v.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

func yesNo(b bool) string {
	if b {
		return "yes"
	}
	return "no"
}

// --- status ------------------------------------------------------------------

func cliStatus() int {
	s, err := req("GET", "/sidecar/status", nil)
	if err != nil {
		return cliFail(err)
	}
	acc, at := obj(s, "account"), obj(s, "attach")
	ssh := obj(s, "ssh")
	fmt.Printf("machine      %s\n", str(s, "machineName"))
	fmt.Printf("user         %s\n", str(s, "user"))
	fmt.Printf("signed in    %s", yesNo(bul(acc, "signedIn")))
	if n := str(acc, "deviceName"); n != "" {
		fmt.Printf("  (%s)", n)
	}
	fmt.Println()
	fmt.Printf("serving      %s\n", yesNo(bul(acc, "serving")))
	fmt.Printf("channel      %s\n", yesNo(bul(acc, "channelConnected")))
	fmt.Printf("attached     %s", yesNo(bul(at, "linked")))
	if t := obj(at, "target"); t != nil {
		fmt.Printf("  -> %s", str(t, "name"))
	}
	if bul(at, "awaitingApproval") {
		fmt.Printf("  (awaiting approval in Bromure AC's fleet dialog)")
	}
	fmt.Println()
	// The real listener state, not the configured port. `status()` already
	// reports `ssh.error` when the bind failed; printing the port regardless
	// claimed a listener that wasn't there. Measured with two daemons on one
	// box: the second logs `couldn't bind 127.0.0.1:2223: address already in
	// use`, keeps running, and this line used to say `ssh 127.0.0.1:2223`
	// anyway -- for the port AC connects through.
	if e := str(ssh, "error"); e != "" {
		fmt.Printf("ssh          NOT LISTENING - %s\n", e)
	} else if p, ok := ssh["port"].(float64); ok {
		fmt.Printf("ssh          127.0.0.1:%d\n", int(p))
	}
	if n, ok := s["agentsRunning"].(float64); ok {
		fmt.Printf("agents       %d running\n", int(n))
	}
	fmt.Printf("pane host    %s\n", yesNo(bul(s, "panesUp")))
	if e := str(acc, "lastError"); e != "" {
		fmt.Printf("last error   %s\n", e)
	}
	return 0
}

// --- the account -------------------------------------------------------------

func cliEnroll(args []string) int {
	if len(args) > 0 {
		// Completing the handoff: the link the browser handed back.
		if _, err := req("POST", "/sidecar/enroll", map[string]any{"link": strings.Join(args, " ")}); err != nil {
			return cliFail(err)
		}
		fmt.Println("enrolled. `bromure-sidecar status` to confirm, then")
		fmt.Println("`bromure-sidecar servers` and `bromure-sidecar link <id>`.")
		return 0
	}
	out, err := req("POST", "/sidecar/signin", map[string]any{})
	if err != nil {
		return cliFail(err)
	}
	u := str(out, "url")
	fmt.Println("Open this on a machine with a browser:")
	fmt.Println()
	fmt.Println("  " + u)
	fmt.Println()
	// No URL-scheme handler and usually no browser here, so the round trip
	// is manual. The daemon has already written the state nonce it will
	// check the link against, so this must be finished from this machine.
	fmt.Println("Sign in there. The page hands back a bromure-agent-host:// link;")
	fmt.Println("paste it back here:")
	fmt.Println()
	fmt.Println("  bromure-sidecar enroll 'bromure-agent-host://enroll?code=…&state=…'")
	return 0
}

func cliSignout() int {
	if _, err := req("POST", "/sidecar/signout", map[string]any{}); err != nil {
		return cliFail(err)
	}
	fmt.Println("signed out and detached.")
	return 0
}

func cliServers() int {
	out, err := req("GET", "/sidecar/servers", nil)
	if err != nil {
		return cliFail(err)
	}
	list, _ := out["servers"].([]any)
	if len(list) == 0 {
		fmt.Println("no servers. Sign in first (bromure-sidecar enroll), and make sure")
		fmt.Println("a Bromure AC on the same account is running.")
		return 0
	}
	for _, it := range list {
		m, _ := it.(map[string]any)
		fmt.Printf("%-38s %-24s %s\n", str(m, "id"), str(m, "name"), str(m, "user"))
	}
	return 0
}

func cliLink(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: bromure-sidecar link <server-id>")
		fmt.Fprintln(os.Stderr, "       bromure-sidecar servers   # to list them")
		return 2
	}
	if _, err := req("POST", "/sidecar/attach", map[string]any{"id": args[0]}); err != nil {
		return cliFail(err)
	}
	fmt.Println("attaching. It is not linked until that Bromure AC admits this")
	fmt.Println("machine in its fleet dialog; `status` shows awaiting approval.")
	return 0
}

func cliUnlink() int {
	if _, err := req("POST", "/sidecar/detach", map[string]any{"forget": true}); err != nil {
		return cliFail(err)
	}
	fmt.Println("detached.")
	return 0
}

// --- sessions ----------------------------------------------------------------

func cliSessions() int {
	out, err := req("GET", "/state", nil)
	if err != nil {
		return cliFail(err)
	}
	vms, _ := out["vms"].([]any)
	rows := 0
	for _, v := range vms {
		vm, _ := v.(map[string]any)
		tabs, _ := vm["tabs"].([]any)
		for _, t := range tabs {
			tab, _ := t.(map[string]any)
			idx := 0
			if f, ok := tab["index"].(float64); ok {
				idx = int(f)
			}
			ag := obj(tab, "agent")
			tool := str(ag, "tool")
			if tool == "" {
				tool = "-"
			}
			alive := ""
			if ag != nil && !bul(ag, "alive") {
				alive = " (exited)"
			}
			fmt.Printf("%-3d %-8s %-12s %-34s %s%s\n", idx, tool,
				str(tab, "agentStatus"), str(tab, "title"), str(tab, "cwd"), alive)
			rows++
		}
	}
	if rows == 0 {
		fmt.Println("no sessions. Start one: bromure-sidecar start claude ~/src/project")
	}
	return 0
}

func cliStart(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: bromure-sidecar start <tool> [directory]")
		fmt.Fprintln(os.Stderr, "       bromure-sidecar agents    # which tools are installed")
		return 2
	}
	body := map[string]any{"tool": args[0]}
	if len(args) > 1 {
		d := args[1]
		// An absolute real path is what AC would send as a virtual one; on
		// Linux they are the same namespace, so only ~ needs expanding.
		if d == "~" || strings.HasPrefix(d, "~/") {
			body["cwd"] = d
		} else if abs, err := filepath.Abs(d); err == nil {
			body["cwd"] = abs
		} else {
			body["cwd"] = d
		}
	}
	out, err := req("POST", "/agent-sessions/start", body)
	if err != nil {
		return cliFail(err)
	}
	w := 0
	if f, ok := out["window"].(float64); ok {
		w = int(f)
	}
	fmt.Printf("started %s in window %d (session %s)\n", args[0], w, str(out, "id"))
	fmt.Printf("attach with: bromure-sidecar attach %d\n", w)
	return 0
}

func cliStop(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: bromure-sidecar stop <window>")
		return 2
	}
	n, err := strconv.Atoi(args[0])
	if err != nil {
		fmt.Fprintln(os.Stderr, "stop: the window is a number (see `sessions`)")
		return 2
	}
	if _, err := req("POST", "/sessions/x/tab", map[string]any{"action": "close", "index": n}); err != nil {
		return cliFail(err)
	}
	fmt.Printf("closed window %d.\n", n)
	return 0
}

// --- agents ------------------------------------------------------------------

func cliAgents(args []string) int {
	if len(args) > 0 && args[0] == "install" {
		if len(args) < 2 {
			fmt.Fprintln(os.Stderr, "usage: bromure-sidecar agents install <tool>")
			return 2
		}
		fmt.Printf("installing %s with its maker's installer; this streams to the log.\n", args[1])
		if _, err := req("POST", "/sidecar/agents/install", map[string]any{"tool": args[1]}); err != nil {
			return cliFail(err)
		}
		fmt.Println("started. Follow it with: bromure-sidecar logs -f")
		return 0
	}
	out, err := req("GET", "/sidecar/install-state", nil)
	if err != nil {
		return cliFail(err)
	}
	list, _ := out["agents"].([]any)
	for _, it := range list {
		m, _ := it.(map[string]any)
		spec, phase := obj(m, "spec"), obj(m, "phase")
		v := str(phase, "version")
		if v != "" {
			v = "v" + v
		}
		fmt.Printf("%-8s %-11s %-10s %s\n", str(spec, "id"), str(phase, "state"), v, str(phase, "path"))
	}
	return 0
}

// --- settings ----------------------------------------------------------------

func cliSettings(args []string) int {
	switch len(args) {
	case 0:
		out, err := req("GET", "/sidecar/settings", nil)
		if err != nil {
			return cliFail(err)
		}
		m := obj(out, "settings")
		keys := make([]string, 0, len(m))
		for k := range m {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			b, _ := json.Marshal(m[k])
			fmt.Printf("%-34s %s\n", k, string(b))
		}
		return 0
	case 1:
		out, err := req("GET", "/sidecar/settings", nil)
		if err != nil {
			return cliFail(err)
		}
		v, ok := obj(out, "settings")[args[0]]
		if !ok {
			fmt.Fprintf(os.Stderr, "settings: %s isn't set\n", args[0])
			return 1
		}
		b, _ := json.Marshal(v)
		fmt.Println(string(b))
		return 0
	default:
		body := map[string]any{"key": args[0]}
		raw := strings.Join(args[1:], " ")
		if raw == "-" {
			body["unset"] = true
		} else {
			// Typed where it parses as JSON (numbers, booleans, objects),
			// a string otherwise: `settings sshPort 2224` must store 2224
			// and not "2224", because the daemon reads it as an int.
			var v any
			if json.Unmarshal([]byte(raw), &v) == nil {
				body["value"] = v
			} else {
				body["value"] = raw
			}
		}
		if _, err := req("POST", "/sidecar/settings", body); err != nil {
			return cliFail(err)
		}
		fmt.Printf("%s set. Some settings are read at startup; restart if it seems ignored:\n", args[0])
		fmt.Println("  systemctl --user restart bromure-sidecar")
		return 0
	}
}

// --- logs --------------------------------------------------------------------

// cliLogs reads the file directly rather than through the daemon: the log is
// most wanted exactly when the daemon will not start.
func cliLogs(args []string) int {
	follow, lines := false, 200
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "-f", "--follow":
			follow = true
		case "-n":
			if i+1 < len(args) {
				if n, err := strconv.Atoi(args[i+1]); err == nil {
					lines = n
				}
				i++
			}
		default:
			fmt.Fprintln(os.Stderr, "usage: bromure-sidecar logs [-f] [-n lines]")
			return 2
		}
	}
	p := paths.LogFile()
	if _, err := os.Stat(p); err != nil {
		fmt.Fprintf(os.Stderr, "logs: no log at %s yet\n", p)
		return 1
	}
	if follow {
		// tail(1) where there is one, so -f behaves exactly as people
		// expect (rotation, Ctrl-C); a Go reimplementation of -f would be
		// worse at both.
		if tail, err := exec.LookPath("tail"); err == nil {
			cmd := exec.Command(tail, "-n", strconv.Itoa(lines), "-F", p)
			cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
			_ = cmd.Run()
			return 0
		}
		fmt.Fprintln(os.Stderr, "logs: -f needs tail(1); printing the tail instead")
	}
	return printTail(p, lines)
}

func printTail(p string, lines int) int {
	f, err := os.Open(p)
	if err != nil {
		return cliFail(err)
	}
	defer f.Close()
	// Read the last ~1 MiB rather than the whole file: a long-running
	// daemon's log is unbounded and `logs` is used casually.
	const window = 1 << 20
	st, _ := f.Stat()
	if st != nil && st.Size() > window {
		_, _ = f.Seek(st.Size()-window, io.SeekStart)
	}
	data, err := io.ReadAll(f)
	if err != nil {
		return cliFail(err)
	}
	all := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	if len(all) > lines {
		all = all[len(all)-lines:]
	}
	fmt.Println(strings.Join(all, "\n"))
	return 0
}

// --- update ------------------------------------------------------------------

func cliUpdate(args []string) int {
	install := len(args) > 0 && (args[0] == "--install" || args[0] == "-i")
	out, err := req("POST", "/sidecar/update-check", map[string]any{})
	if err != nil {
		return cliFail(err)
	}

	// Linux does not self-update: releases come from the Bromure package
	// repo. The daemon reports how this binary was installed, and this
	// prints -- or runs -- the command that updates it. Run from HERE and
	// not from the daemon, because sudo needs a terminal to prompt on and
	// the daemon has none.
	if kind := str(out, "installKind"); kind != "" {
		fmt.Printf("running %s, %s\n", str(out, "version"), str(out, "hint"))
		argv := []string{}
		for _, a := range sliceOf(out, "commandArgv") {
			argv = append(argv, a)
		}
		if kind == "tarball" || len(argv) == 0 {
			fmt.Println()
			fmt.Println("To update, reinstall: unpack the newest release tarball and run")
			fmt.Println("  ./install.sh ./bromure-sidecar")
			fmt.Println("Or install the .deb/.rpm from the Bromure repo to get updates")
			fmt.Println("with the rest of the system (see packaging/REPO.md).")
			return 0
		}
		// The package metadata has to be current or apt reports the
		// installed version as newest; dnf refreshes on its own.
		refresh := []string{}
		if kind == "deb" {
			refresh = []string{"apt-get", "update"}
			if argv[0] == "apt" {
				refresh = []string{"apt", "update"}
			}
		}
		if !install {
			fmt.Println()
			fmt.Println("Update with:")
			if len(refresh) > 0 {
				fmt.Printf("  sudo %s\n", strings.Join(refresh, " "))
			}
			fmt.Printf("  sudo %s\n", strings.Join(argv, " "))
			fmt.Println()
			fmt.Println("or `bromure-sidecar update --install` to run that now.")
			fmt.Println("The running daemon keeps its old binary until")
			fmt.Println("`systemctl --user restart bromure-sidecar`; agents survive that.")
			return 0
		}
		for _, c := range [][]string{refresh, argv} {
			if len(c) == 0 {
				continue
			}
			fmt.Printf("+ sudo %s\n", strings.Join(c, " "))
			cmd := exec.Command("sudo", c...)
			cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
			if err := cmd.Run(); err != nil {
				fmt.Fprintf(os.Stderr, "update: %s failed: %v\n", c[0], err)
				return 1
			}
		}
		fmt.Println()
		fmt.Println("installed. The running daemon still has the old binary; pick up the")
		fmt.Println("new one with: systemctl --user restart bromure-sidecar")
		fmt.Println("(agents survive the restart -- see KillMode=process in the unit).")
		return 0
	}

	// Windows: the release feed, unchanged.
	if !bul(out, "available") {
		fmt.Printf("up to date (%s)\n", str(out, "version"))
		return 0
	}
	fmt.Printf("%s is available (running %s)\n", str(out, "version"), version)
	if !install {
		fmt.Println("install it with: bromure-sidecar update --install")
		return 0
	}
	if _, err := req("POST", "/sidecar/update-install", map[string]any{}); err != nil {
		return cliFail(err)
	}
	fmt.Println("installing.")
	return 0
}

// --- shutdown ----------------------------------------------------------------

// cliShutdown stops the agents and then the daemon. `systemctl --user stop`
// deliberately leaves the pane host running (KillMode=process, so a daemon
// restart does not kill agents), so there has to be one command that means
// "stop everything".
func cliShutdown() int {
	if _, err := req("POST", "/sidecar/panehost-stop", map[string]any{"force": false}); err != nil {
		// A pane host with live windows refuses; say so instead of leaving
		// the user to read a 409.
		fmt.Fprintf(os.Stderr, "shutdown: the pane host wouldn't stop: %v\n", err)
		fmt.Fprintln(os.Stderr, "  agents are still running. Close them (`sessions`, `stop <n>`),")
		fmt.Fprintln(os.Stderr, "  or force it: bromure-sidecar ctl panehost-stop '{\"force\":true}'")
		return 1
	}
	if _, err := req("POST", "/sidecar/quit", map[string]any{}); err != nil {
		return cliFail(err)
	}
	fmt.Println("stopped the pane host and the daemon.")
	if runtime.GOOS == "linux" {
		fmt.Println("(systemd will restart it on failure only; `systemctl --user start")
		fmt.Println(" bromure-sidecar` brings it back.)")
	}
	return 0
}
