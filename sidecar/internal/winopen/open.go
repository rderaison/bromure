// Package winopen opens a URL in the user's browser on any OS.
package winopen

import (
	"os/exec"
	"runtime"
)

// URL opens u in the default browser.
func URL(u string) error {
	switch runtime.GOOS {
	case "windows":
		return start(exec.Command("rundll32", "url.dll,FileProtocolHandler", u))
	case "darwin":
		return start(exec.Command("open", u))
	}
	return start(exec.Command("xdg-open", u))
}

// start launches the opener and reaps it. These helpers hand the URL to the
// desktop and exit immediately, so nothing waits for them -- and an unwaited
// child stays a zombie for as long as the daemon lives, one per call.
// Observed: a defunct xdg-open under a long-running `serve`.
//
// The exit status is deliberately dropped. It says whether the HELPER ran,
// not whether a browser appeared, and by the time it arrives the caller has
// long since returned.
func start(cmd *exec.Cmd) error {
	if err := cmd.Start(); err != nil {
		return err
	}
	go func() { _ = cmd.Wait() }()
	return nil
}
