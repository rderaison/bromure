//go:build linux

package updater

// How a Linux Sidecar updates: not by replacing itself.
//
// Updates come from the Bromure package repo (apt, dnf, zypper). So instead
// of a feed and a downloader, this works out how THIS binary was installed
// and names the command that updates it. The CLI prints that, and runs it
// only when asked -- in the CLI's own process, so sudo has a terminal to
// prompt on; the daemon has none.

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// InstallMethod is how this binary got here.
type InstallMethod struct {
	Kind    string   // "deb", "rpm", "tarball"
	Package string   // the owning package, when one owns it
	Command []string // what updates it ("" for a tarball)
	Hint    string   // what to tell the user
}

// Method asks the package databases which package owns this executable.
// Asked of the RESOLVED path: ~/.local/bin/bromure-sidecar may be a symlink
// to a packaged /usr/bin copy, and dpkg only knows the real path.
func Method() InstallMethod {
	exe, err := os.Executable()
	if err == nil {
		if p, e := filepath.EvalSymlinks(exe); e == nil {
			exe = p
		}
	}

	if pkg, ok := owner("dpkg", []string{"-S", exe}, exe); ok {
		cmd := []string{"apt-get", "install", "--only-upgrade", pkg}
		if _, err := exec.LookPath("apt"); err == nil {
			cmd = []string{"apt", "install", "--only-upgrade", pkg}
		}
		return InstallMethod{Kind: "deb", Package: pkg, Command: cmd,
			Hint: "installed from a .deb"}
	}
	if pkg, ok := owner("rpm", []string{"-qf", "--queryformat", "%{NAME}", exe}, exe); ok {
		// Whichever front end this distribution has: dnf (Fedora, RHEL 8+),
		// zypper (SUSE), then yum (older RHEL/CentOS).
		for _, c := range [][]string{
			{"dnf", "upgrade", pkg},
			{"zypper", "update", pkg},
			{"yum", "update", pkg},
		} {
			if _, err := exec.LookPath(c[0]); err == nil {
				return InstallMethod{Kind: "rpm", Package: pkg, Command: c,
					Hint: "installed from an .rpm"}
			}
		}
		return InstallMethod{Kind: "rpm", Package: pkg,
			Hint: "installed from an .rpm, but no dnf/zypper/yum was found"}
	}
	return InstallMethod{Kind: "tarball",
		Hint: "installed from the release tarball (or built from source)"}
}

// owner runs a package-database query and returns the package that owns exe.
// A query that is missing, fails, or answers about a different file means
// "not owned": `dpkg -S` exits non-zero for an unpackaged path, and on a
// system without dpkg the binary is simply absent.
func owner(tool string, args []string, exe string) (string, bool) {
	if exe == "" {
		return "", false
	}
	if _, err := exec.LookPath(tool); err != nil {
		return "", false
	}
	out, err := exec.Command(tool, args...).Output()
	if err != nil {
		return "", false
	}
	line := strings.TrimSpace(string(out))
	if line == "" || strings.Contains(line, "not owned by any package") {
		return "", false
	}
	switch tool {
	case "dpkg":
		// "bromure-sidecar: /usr/bin/bromure-sidecar", and a diversion line
		// can precede it, so take the last line that names this file.
		pkg := ""
		for _, l := range strings.Split(line, "\n") {
			i := strings.Index(l, ": ")
			if i <= 0 || strings.TrimSpace(l[i+2:]) != exe {
				continue
			}
			pkg = strings.TrimSpace(l[:i])
		}
		if pkg == "" {
			return "", false
		}
		// A dpkg package may be listed as "name:arch"; apt takes either, but
		// the bare name is what a person expects to read.
		if i := strings.IndexByte(pkg, ':'); i > 0 {
			pkg = pkg[:i]
		}
		return pkg, true
	default:
		// With --queryformat '%{NAME}' this is the bare package name and no
		// newline. Asked for the NAME and not the default NVR, because
		// `rpm -qf` prints "bromure-sidecar-1.0.2.test-1.aarch64" and
		// `dnf upgrade` on that names the version already installed.
		f := strings.Fields(line)
		if len(f) == 0 {
			return "", false
		}
		return f[0], true
	}
}
