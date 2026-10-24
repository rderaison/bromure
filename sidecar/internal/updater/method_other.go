//go:build !linux

package updater

// InstallMethod and Method exist on every platform so the control route and the
// CLI need no build tags of their own. Off Linux there is no package
// manager in play: Windows updates through the feed above, and the Go
// Sidecar on macOS is a test build.
type InstallMethod struct {
	Kind    string
	Package string
	Command []string
	Hint    string
}

// Method reports nothing to do: Kind is empty off Linux.
func Method() InstallMethod { return InstallMethod{} }
