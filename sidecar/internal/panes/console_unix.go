//go:build !windows

package panes

import (
	"os"
	"os/signal"
	"syscall"

	xterm "golang.org/x/term"
)

func setupConsole(inFd, outFd int) (func(), error) {
	st, err := xterm.MakeRaw(inFd)
	if err != nil {
		return nil, err
	}
	return func() { xterm.Restore(inFd, st) }, nil
}

// watchSize follows SIGWINCH.
func watchSize(outFd int, f func(cols, rows int)) func() {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGWINCH)
	stop := make(chan struct{})
	go func() {
		for {
			select {
			case <-stop:
				return
			case <-ch:
				if c, r, err := xterm.GetSize(outFd); err == nil {
					f(c, r)
				}
			}
		}
	}()
	return func() { signal.Stop(ch); close(stop) }
}
