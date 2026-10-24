//go:build windows

package panes

import (
	"time"

	"golang.org/x/sys/windows"
	xterm "golang.org/x/term"
)

// setupConsole: raw input with VT input sequences, VT output processing,
// UTF-8 code pages.
func setupConsole(inFd, outFd int) (func(), error) {
	st, err := xterm.MakeRaw(inFd) // also turns ENABLE_VIRTUAL_TERMINAL_INPUT on
	if err != nil {
		return nil, err
	}
	in := windows.Handle(inFd)
	var inMode uint32
	if windows.GetConsoleMode(in, &inMode) == nil {
		windows.SetConsoleMode(in, inMode|windows.ENABLE_VIRTUAL_TERMINAL_INPUT)
	}
	out := windows.Handle(outFd)
	var outMode uint32
	haveOut := windows.GetConsoleMode(out, &outMode) == nil
	if haveOut {
		windows.SetConsoleMode(out, outMode|windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING|windows.ENABLE_PROCESSED_OUTPUT|windows.DISABLE_NEWLINE_AUTO_RETURN)
	}
	inCP, _ := windows.GetConsoleCP()
	outCP, _ := windows.GetConsoleOutputCP()
	windows.SetConsoleCP(65001)
	windows.SetConsoleOutputCP(65001)
	return func() {
		xterm.Restore(inFd, st)
		if haveOut {
			windows.SetConsoleMode(out, outMode)
		}
		if inCP != 0 {
			windows.SetConsoleCP(inCP)
		}
		if outCP != 0 {
			windows.SetConsoleOutputCP(outCP)
		}
	}, nil
}

// watchSize polls the console size (Windows has no SIGWINCH).
func watchSize(outFd int, f func(cols, rows int)) func() {
	stop := make(chan struct{})
	go func() {
		lc, lr, _ := xterm.GetSize(outFd)
		t := time.NewTicker(250 * time.Millisecond)
		defer t.Stop()
		for {
			select {
			case <-stop:
				return
			case <-t.C:
				c, r, err := xterm.GetSize(outFd)
				if err == nil && (c != lc || r != lr) {
					lc, lr = c, r
					f(c, r)
				}
			}
		}
	}()
	return func() { close(stop) }
}
