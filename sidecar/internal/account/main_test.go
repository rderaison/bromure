package account

import (
	"os"
	"testing"

	"github.com/rderaison/bromure/sidecar/internal/paths"
)

// Logs go to a scratch data dir, never the user's.
func TestMain(m *testing.M) {
	dir, _ := os.MkdirTemp("", "bromure-p2p-test")
	paths.SetDataDirForTest(dir)
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}
