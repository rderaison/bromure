//go:build !windows

package main

import (
	"fmt"
	"os"
)

var version = "dev"

// The tray is the Windows front end; on macOS and Linux run the daemon
// directly (`bromure-sidecar serve`) and drive it with `bromure-sidecar ctl`.
func main() {
	fmt.Fprintln(os.Stderr, "BromureSidecar (tray) is Windows-only; run `bromure-sidecar serve` and use `bromure-sidecar ctl`.")
	os.Exit(2)
}
