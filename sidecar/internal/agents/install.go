package agents

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/hostexec"
	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/paths"
)

var ansi = regexp.MustCompile(`\x1b\[[0-9;?]*[A-Za-z]`)

// Install runs the chosen agents' installers one after another, in the
// background. Each is the maker's own command; nothing is fetched by us.
func Install(ids []string) error {
	var specs []Spec
	for _, id := range ids {
		s, ok := Get(id)
		if !ok {
			return fmt.Errorf("unknown agent %s", id)
		}
		if s.Install == "" {
			return fmt.Errorf("%s: %s", s.Name, NotOnWindows)
		}
		specs = append(specs, s)
	}
	if len(specs) == 0 {
		return fmt.Errorf("nothing to install")
	}
	mu.Lock()
	if busy {
		mu.Unlock()
		return fmt.Errorf("an install is already under way")
	}
	busy = true
	for _, s := range specs {
		phases[s.ID] = Phase{State: "queued"}
		logs[s.ID] = ""
	}
	mu.Unlock()
	go func() {
		for _, s := range specs {
			setPhase(s.ID, Phase{State: "installing", Line: "Starting…"})
			ok := runInstaller(s, func(line string) {
				mu.Lock()
				logs[s.ID] += line + "\n"
				if phases[s.ID].State == "installing" {
					phases[s.ID] = Phase{State: "installing", Line: line}
				}
				mu.Unlock()
			})
			logx.Printf("agents: %s installer %s", s.ID, map[bool]string{true: "finished", false: "failed"}[ok])
			// Installers add their folder to the user PATH: sessions started
			// from now on get it.
			hostexec.RefreshPath()
			p := detect(s.ID)
			if p.State != "installed" {
				tail := lastLine(Log(s.ID))
				msg := "The installer failed."
				if ok {
					msg = "Installed, but `" + s.ID + "` isn't found on your PATH yet."
				} else if tail != "" {
					msg = tail
				}
				p = Phase{State: "failed", Line: msg}
			}
			setPhase(s.ID, p)
		}
		mu.Lock()
		busy = false
		mu.Unlock()
	}()
	return nil
}

func setPhase(id string, p Phase) {
	mu.Lock()
	phases[id] = p
	mu.Unlock()
}

func lastLine(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	return strings.TrimSpace(lines[len(lines)-1])
}

// runInstaller runs one installer, its output streamed line by line (ANSI
// stripped, \r as a line end: progress bars).
func runInstaller(s Spec, onLine func(string)) bool {
	var cmd *exec.Cmd
	env := hostexec.AgentEnv()
	env = hostexec.EnvSet(env, "PATH", searchPath())
	env = hostexec.EnvSet(env, "NO_COLOR", "1")
	env = hostexec.EnvSet(env, "CI", "1")
	env = hostexec.EnvSet(env, "TERM", "dumb")
	if runtime.GOOS == "windows" {
		// The maker's PowerShell installer, as its docs say (`irm … | iex`),
		// with nothing to answer: Codex asks before replacing an older
		// install unless told it's non-interactive.
		env = hostexec.EnvSet(env, "CODEX_NON_INTERACTIVE", "1")
		cmd = exec.Command(powershell(), "-NoLogo", "-NoProfile", "-NonInteractive",
			"-ExecutionPolicy", "Bypass", "-Command",
			"$ProgressPreference = 'SilentlyContinue'; "+s.Install)
	} else {
		cmd = exec.Command("/bin/bash", "-c", "set -o pipefail; "+s.Install)
		env = hostexec.EnvSet(env, "PATH", "/usr/bin:/bin:/usr/sbin:/sbin:"+hostexec.EnvGet(env, "PATH"))
	}
	cmd.Env = env
	cmd.Dir = paths.Home()
	hideWindow(cmd)
	pr, pw := io.Pipe()
	cmd.Stdout = pw
	cmd.Stderr = pw
	if err := cmd.Start(); err != nil {
		onLine("Couldn't start the installer: " + err.Error())
		return false
	}
	go func() {
		sc := bufio.NewScanner(pr)
		sc.Buffer(make([]byte, 64<<10), 1<<20)
		sc.Split(scanLinesCR)
		for sc.Scan() {
			if l := strings.TrimSpace(ansi.ReplaceAllString(sc.Text(), "")); l != "" {
				onLine(l)
			}
		}
	}()
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	var err error
	select {
	case err = <-done:
	case <-time.After(15 * time.Minute):
		_ = cmd.Process.Kill()
		err = <-done
	}
	pw.Close()
	return err == nil
}

func scanLinesCR(data []byte, atEOF bool) (int, []byte, error) {
	for i, b := range data {
		if b == '\n' || b == '\r' {
			return i + 1, data[:i], nil
		}
	}
	if atEOF && len(data) > 0 {
		return len(data), data, nil
	}
	return 0, nil, nil
}

// powershell is Windows PowerShell (always there), by full path.
func powershell() string {
	root := os.Getenv("SystemRoot")
	if root == "" {
		root = `C:\Windows`
	}
	p := filepath.Join(root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	if _, err := os.Stat(p); err == nil {
		return p
	}
	return "powershell.exe"
}
