//go:build windows

package hostexec

import "golang.org/x/sys/windows/registry"

// gitInstallRoots reads Git for Windows' InstallPath: the machine-wide
// install, then a per-user one.
func gitInstallRoots() []string {
	var out []string
	for _, root := range []registry.Key{registry.LOCAL_MACHINE, registry.CURRENT_USER} {
		k, err := registry.OpenKey(root, `SOFTWARE\GitForWindows`, registry.QUERY_VALUE|registry.WOW64_64KEY)
		if err != nil {
			continue
		}
		if v, _, err := k.GetStringValue("InstallPath"); err == nil && v != "" {
			out = append(out, v)
		}
		k.Close()
	}
	return out
}
