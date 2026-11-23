//go:build windows

package hostexec

import (
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/windows/registry"

	"github.com/rderaison/bromure/sidecar/internal/logx"
)

// RefreshPath merges the PATH the registry holds now (machine, then
// user) into this process's: an installer that added its folder after we
// started is found without a new login (the macOS Sidecar re-reads its
// login shell's PATH for the same reason). Entries already there keep
// their order; new ones go after them.
func RefreshPath() {
	var fresh []string
	for _, k := range []struct {
		root registry.Key
		path string
	}{
		{registry.LOCAL_MACHINE, `SYSTEM\CurrentControlSet\Control\Session Manager\Environment`},
		{registry.CURRENT_USER, `Environment`},
	} {
		key, err := registry.OpenKey(k.root, k.path, registry.QUERY_VALUE)
		if err != nil {
			continue
		}
		v, _, err := key.GetStringValue("Path")
		key.Close()
		if err != nil {
			continue
		}
		if x, err := registry.ExpandString(v); err == nil {
			v = x
		}
		fresh = append(fresh, filepath.SplitList(v)...)
	}
	cur := filepath.SplitList(os.Getenv("PATH"))
	seen := map[string]bool{}
	for _, p := range cur {
		seen[strings.ToLower(strings.TrimRight(p, `\`))] = true
	}
	added := 0
	for _, p := range fresh {
		n := strings.ToLower(strings.TrimRight(p, `\`))
		if p == "" || seen[n] {
			continue
		}
		seen[n] = true
		cur = append(cur, p)
		added++
	}
	if added > 0 {
		os.Setenv("PATH", strings.Join(cur, string(os.PathListSeparator)))
		logx.Printf("env: %d new PATH folder(s) from the registry", added)
	}
}
