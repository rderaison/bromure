// Package logx is the Sidecar's log: stderr plus logs/bromure-sidecar.log
// (a tray app's stderr goes nowhere). Never log secrets.
package logx

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/paths"
)

var (
	mu      sync.Mutex
	file    *os.File
	opened  bool
	quiet   bool
	maxSize int64 = 8 << 20
)

// Quiet stops the stderr copy (helpers whose stderr a caller reads: the
// shims, the hook).
func Quiet() { mu.Lock(); quiet = true; mu.Unlock() }

// Printf logs one line.
func Printf(format string, a ...any) {
	line := time.Now().Format("2006-01-02T15:04:05.000Z07:00") + " " + fmt.Sprintf(format, a...) + "\n"
	mu.Lock()
	defer mu.Unlock()
	if !quiet {
		os.Stderr.WriteString(line)
	}
	if !opened {
		opened = true
		p := paths.LogFile()
		_ = os.MkdirAll(filepath.Dir(p), 0o700)
		// One rotation: a long-lived daemon's log never grows without bound.
		if st, err := os.Stat(p); err == nil && st.Size() > maxSize {
			_ = os.Rename(p, p+".1")
		}
		file, _ = os.OpenFile(p, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	}
	if file != nil {
		file.WriteString(line)
	}
}

// Once logs a line the first time key is seen (gaps in the shims show up
// without flooding the log).
var seen sync.Map

func Once(key, format string, a ...any) {
	if _, dup := seen.LoadOrStore(key, true); dup {
		return
	}
	Printf(format, a...)
}
