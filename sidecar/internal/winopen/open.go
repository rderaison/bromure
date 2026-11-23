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
		return exec.Command("rundll32", "url.dll,FileProtocolHandler", u).Start()
	case "darwin":
		return exec.Command("open", u).Start()
	}
	return exec.Command("xdg-open", u).Start()
}
