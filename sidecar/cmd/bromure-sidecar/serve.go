package main

import (
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"syscall"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/agents"
	"github.com/rderaison/bromure/sidecar/internal/control"
	"github.com/rderaison/bromure/sidecar/internal/ctlclient"
	"github.com/rderaison/bromure/sidecar/internal/hooks"
	"github.com/rderaison/bromure/sidecar/internal/hostexec"
	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/panes"
	"github.com/rderaison/bromure/sidecar/internal/paths"
	"github.com/rderaison/bromure/sidecar/internal/sessions"
)

// quit is closed by `/sidecar/quit` (the tray's Quit; the pane host and
// its agents stay).
var quit = make(chan struct{})

func serve(args []string) int {
	if err := paths.Ensure(); err != nil {
		fmt.Fprintln(os.Stderr, "serve: "+err.Error())
		return 1
	}
	if ctlclient.Healthy() {
		fmt.Fprintln(os.Stderr, "serve: Bromure Sidecar is already running")
		return 0
	}
	// Started from inside a Claude Code session (a terminal tab, `claude`
	// launcher): its session markers must not reach the agents we start —
	// an inherited CLAUDE_CODE_CHILD_SESSION turns their transcripts off.
	for _, k := range []string{"CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "CLAUDE_CODE_CHILD_SESSION",
		"CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_TUI_JUST_SWITCHED", "CLAUDE_CODE_MESSAGING_SOCKET",
		"CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_ENTRYPOINT",
		"CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_SSE_PORT"} {
		os.Unsetenv(k)
	}
	logx.Printf("serve: bromure-sidecar %s starting (%s/%s, data %s)", version, runtime.GOOS, runtime.GOARCH, paths.DataDir())
	installBinaries()
	if err := hostexec.WriteBashEnv(); err != nil {
		logx.Printf("serve: bash-env: %v", err)
	}
	if err := hooks.WriteSettings(); err != nil {
		logx.Printf("serve: claude settings: %v", err)
	}
	if sh := hostexec.FindShell(); sh == nil {
		logx.Printf("serve: no bash found — install Git for Windows (winget install --id Git.Git -e)")
	} else {
		logx.Printf("serve: shell %s", sh.Bash)
	}
	hostexec.StartTerminal = startTerminal
	// The pane host: started (detached) if it isn't running; an older idle
	// one is replaced, one with windows is kept until it's idle.
	if c, err := panes.EnsureHost(); err != nil {
		logx.Printf("serve: pane host: %v", err)
	} else {
		c.Close()
	}
	upgradePaneHostWhenIdle()

	engine := sessions.New(panes.Connect)
	agents.Panes = panes.Connect
	go agents.Scan()

	api := &control.API{Engine: engine, Panes: panes.Connect}
	srv := &control.Server{Route: api.Route}
	if err := srv.Listen(paths.ControlSocket()); err != nil {
		logx.Printf("serve: control: %v", err)
		return 1
	}
	stopLoops := make(chan struct{})
	go engine.BranchLoop(stopLoops)
	go func() {
		// Keep the session list reconciled even when nobody polls.
		t := time.NewTicker(5 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-stopLoops:
				return
			case <-t.C:
				engine.Snapshot()
			}
		}
	}()

	rem := startRemote(engine, srv)
	api.Keys = rem.keys
	api.Sidecar = &sidecarAPI{engine: engine, remote: rem}

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	select {
	case s := <-sig:
		logx.Printf("serve: %v — stopping", s)
	case <-quit:
		logx.Printf("serve: quit requested — stopping (agents keep running in the pane host)")
	}
	close(stopLoops)
	rem.stop()
	srv.Close()
	_ = os.Remove(paths.ControlSocket())
	return 0
}

// installBinaries refreshes bin/: the stable executable agents call back
// into, and the tmux / ps shims (copies of this binary that dispatch on
// their name; links on macOS and Linux). A copy in use (an agent's
// delegation shim runs from it) can't be overwritten on Windows, but can
// be renamed aside.
func installBinaries() {
	self := paths.Executable()
	dst := []string{hostexec.StableExecutable(),
		filepath.Join(paths.BinDir(), paths.ExeName("tmux")),
		filepath.Join(paths.BinDir(), paths.ExeName("ps"))}
	for _, d := range dst {
		if runtime.GOOS != "windows" {
			if cur, err := os.Readlink(d); err == nil && cur == self {
				continue
			}
			_ = os.Remove(d)
			if err := os.Symlink(self, d); err != nil {
				logx.Printf("serve: link %s: %v", d, err)
			}
			continue
		}
		if sameFile(self, d) {
			continue
		}
		if err := copyFile(self, d); err != nil {
			old := d + ".old-" + strconv.FormatInt(time.Now().Unix(), 10)
			if rerr := os.Rename(d, old); rerr == nil {
				err = copyFile(self, d)
			}
			if err != nil {
				logx.Printf("serve: install %s: %v", d, err)
			}
		}
	}
	// Old copies left by earlier renames go once nothing runs them.
	olds, _ := filepath.Glob(filepath.Join(paths.BinDir(), "*.old-*"))
	for _, o := range olds {
		_ = os.Remove(o)
	}
}

func sameFile(a, b string) bool {
	sa, err1 := os.Stat(a)
	sb, err2 := os.Stat(b)
	return err1 == nil && err2 == nil && sa.Size() == sb.Size() && !sb.ModTime().Before(sa.ModTime())
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp := dst + ".tmp"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(tmp)
		return err
	}
	out.Close()
	_ = os.Remove(dst)
	return os.Rename(tmp, dst)
}

// upgradePaneHostWhenIdle replaces an older pane host the next time it
// has no windows (agents never die for an update).
func upgradePaneHostWhenIdle() {
	go func() {
		for {
			ver, windows, err := panes.HostInfo()
			if err != nil || ver >= panes.HostVersion {
				return
			}
			if windows == 0 {
				logx.Printf("serve: replacing the idle pane host (v%d → v%d)", ver, panes.HostVersion)
				_ = panes.StopHost(false)
				if c, err := panes.EnsureHost(); err == nil {
					c.Close()
				}
				return
			}
			time.Sleep(time.Minute)
		}
	}()
}

// ensureDaemon: the control socket answers, or the daemon was started and
// it came up.
func ensureDaemon() bool {
	if ctlclient.Healthy() {
		return true
	}
	if err := spawnDetached(paths.Executable(), "serve"); err != nil {
		return false
	}
	for i := 0; i < 50; i++ {
		if ctlclient.Healthy() {
			return true
		}
		time.Sleep(200 * time.Millisecond)
	}
	return false
}
