package agents

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestEveryAgentInstallsHere(t *testing.T) {
	for _, s := range All() {
		if s.Install == "" || s.Unavailable != "" {
			t.Errorf("%s has no installer on %s", s.ID, runtime.GOOS)
		}
		if runtime.GOOS == "windows" && InstallScript(s.ID) != s.Install {
			t.Errorf("%s: %q", s.ID, s.Install)
		}
	}
}

func TestVersionNumber(t *testing.T) {
	for in, want := range map[string]string{
		"2.1.284 (Claude Code)": "2.1.284", "codex-cli 0.9.1": "0.9.1", "kimi, version 1.2.0-beta.3": "1.2.0-beta.3", "": "installed",
	} {
		if got := VersionNumber(in); got != want {
			t.Errorf("VersionNumber(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestNpmShimResolvesToNode(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("npm .cmd shims are Windows-only")
	}
	dir := t.TempDir()
	script := filepath.Join(dir, "node_modules", "@x", "tool", "bin", "tool.js")
	os.MkdirAll(filepath.Dir(script), 0o755)
	os.WriteFile(script, []byte("//"), 0o644)
	os.WriteFile(filepath.Join(dir, "node.exe"), []byte{}, 0o755)
	shim := "@ECHO off\r\nendLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & \"%_prog%\"  " +
		`"%dp0%\node_modules\@x\tool\bin\tool.js" %*` + "\r\n"
	os.WriteFile(filepath.Join(dir, "faketool.cmd"), []byte(shim), 0o644)
	t.Setenv("PATH", dir)
	got := Command("faketool")
	if len(got) != 2 || got[0] != filepath.Join(dir, "node.exe") || got[1] != script {
		t.Fatalf("Command = %v", got)
	}
}
