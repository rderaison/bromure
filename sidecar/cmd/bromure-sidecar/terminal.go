package main

import (
	"github.com/rderaison/bromure/sidecar/internal/hostexec"
	"github.com/rderaison/bromure/sidecar/internal/pty"
)

// startTerminal is a fresh pseudoconsole running `command` under bash
// (empty: an interactive login shell) — a client terminal tab that isn't
// a window attach.
func startTerminal(command string, env []string, dir string, cols, rows int) (hostexec.Terminal, error) {
	sh := hostexec.FindShell()
	argv := []string{sh.Bash, "--login", "-i"}
	if command != "" {
		argv = append([]string{sh.Bash}, hostexec.BashArgs(command)...)
	} else {
		// An interactive shell is the user's: their profile, normal MSYS
		// path conversion.
		env = hostexec.EnvDel(env, "MSYS_NO_PATHCONV")
		env = hostexec.EnvDel(env, "MSYS2_ARG_CONV_EXCL")
		env = hostexec.EnvDel(env, "BASH_ENV")
	}
	return pty.Start(pty.Spec{Argv: argv, Env: env, Dir: dir, Cols: cols, Rows: rows})
}
