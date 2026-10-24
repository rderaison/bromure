package shims

import (
	"sort"
	"strings"
)

// tmuxCommands is tmux 3.4's command table (name, alias): prefixes and
// aliases resolve as in cmd_find, so `display`, `capturep` and `lsw` work
// and `list` is ambiguous exactly as in tmux.
var tmuxCommands = [][2]string{
	{"attach-session", "attach"}, {"bind-key", "bind"}, {"break-pane", "breakp"},
	{"capture-pane", "capturep"}, {"choose-buffer", ""}, {"choose-client", ""},
	{"choose-tree", ""}, {"clear-history", "clearhist"}, {"clear-prompt-history", "clearphist"},
	{"clock-mode", ""}, {"command-prompt", ""}, {"confirm-before", "confirm"},
	{"copy-mode", ""}, {"customize-mode", ""}, {"delete-buffer", "deleteb"},
	{"detach-client", "detach"}, {"display-menu", "menu"}, {"display-message", "display"},
	{"display-popup", "popup"}, {"display-panes", "displayp"}, {"find-window", "findw"},
	{"has-session", "has"}, {"if-shell", "if"}, {"join-pane", "joinp"},
	{"kill-pane", "killp"}, {"kill-server", ""}, {"kill-session", ""},
	{"kill-window", "killw"}, {"last-pane", "lastp"}, {"last-window", "last"},
	{"link-window", "linkw"}, {"list-buffers", "lsb"}, {"list-clients", "lsc"},
	{"list-commands", "lscm"}, {"list-keys", "lsk"}, {"list-panes", "lsp"},
	{"list-sessions", "ls"}, {"list-windows", "lsw"}, {"load-buffer", "loadb"},
	{"lock-client", "lockc"}, {"lock-server", "lock"}, {"lock-session", "locks"},
	{"move-pane", "movep"}, {"move-window", "movew"}, {"new-session", "new"},
	{"new-window", "neww"}, {"next-layout", "nextl"}, {"next-window", "next"},
	{"paste-buffer", "pasteb"}, {"pipe-pane", "pipep"}, {"previous-layout", "prevl"},
	{"previous-window", "prev"}, {"refresh-client", "refresh"}, {"rename-session", "rename"},
	{"rename-window", "renamew"}, {"resize-pane", "resizep"}, {"resize-window", "resizew"},
	{"respawn-pane", "respawnp"}, {"respawn-window", "respawnw"}, {"rotate-window", "rotatew"},
	{"run-shell", "run"}, {"save-buffer", "saveb"}, {"select-layout", "selectl"},
	{"select-pane", "selectp"}, {"select-window", "selectw"}, {"send-keys", "send"},
	{"send-prefix", ""}, {"server-access", ""}, {"set-buffer", "setb"},
	{"set-environment", "setenv"}, {"set-hook", ""}, {"set-option", "set"},
	{"set-window-option", "setw"}, {"show-buffer", "showb"}, {"show-environment", "showenv"},
	{"show-hooks", ""}, {"show-messages", "showmsgs"}, {"show-options", "show"},
	{"show-prompt-history", "showphist"}, {"show-window-options", "showw"},
	{"source-file", "source"}, {"split-window", "splitw"}, {"start-server", "start"},
	{"suspend-client", "suspendc"}, {"swap-pane", "swapp"}, {"swap-window", "swapw"},
	{"switch-client", "switchc"}, {"unbind-key", "unbind"}, {"unlink-window", "unlinkw"},
	{"wait-for", "wait"},
}

// cmdSpec is one command the shim serves.
type cmdSpec struct {
	name  string
	flags string // getopt: "aF:t:" (a letter then ':' takes a value)
	min   int
	max   int // -1: any
	run   func(r *tmuxRun, a *cmdArgs) error
}

// cmdArgs is a parsed command: flag values (in order; a flag without a
// value records "") and the positional arguments.
type cmdArgs struct {
	name  string
	flags map[byte][]string
	args  []string
}

func (a *cmdArgs) has(f byte) bool { return len(a.flags[f]) > 0 }

// get is the last value given for a flag.
func (a *cmdArgs) get(f byte) (string, bool) {
	v := a.flags[f]
	if len(v) == 0 {
		return "", false
	}
	return v[len(v)-1], true
}

type parsedCmd struct {
	spec *cmdSpec
	args *cmdArgs
}

// splitCommands splits argv on `;` the way cmd_parse_from_arguments does:
// a lone ";" separates; an argument ending in ";" ends its command (the ";"
// dropped) unless it ends in "\;", which keeps a literal ";".
func splitCommands(args []string) [][]string {
	var out [][]string
	var cur []string
	for _, a := range args {
		switch {
		case a == ";":
			out = append(out, cur)
			cur = nil
		case strings.HasSuffix(a, "\\;"):
			cur = append(cur, a[:len(a)-2]+";")
		case len(a) > 1 && strings.HasSuffix(a, ";"):
			cur = append(cur, a[:len(a)-1])
			out = append(out, cur)
			cur = nil
		default:
			cur = append(cur, a)
		}
	}
	if len(cur) > 0 {
		out = append(out, cur)
	}
	return out
}

// findCommand is cmd_find: alias, exact name, or a unique prefix.
func findCommand(name string) (string, error) {
	var found []string
	for _, c := range tmuxCommands {
		if c[1] != "" && c[1] == name {
			return c[0], nil
		}
	}
	for _, c := range tmuxCommands {
		if c[0] == name {
			return name, nil
		}
		if strings.HasPrefix(c[0], name) {
			found = append(found, c[0])
		}
	}
	switch len(found) {
	case 0:
		return "", errf("unknown command: %s", name)
	case 1:
		return found[0], nil
	}
	sort.Strings(found)
	return "", errf("ambiguous command: %s, could be: %s", name, strings.Join(found, ", "))
}

// parseList parses every command before any runs (tmux does too: a typo
// in the third command means none runs).
func (r *tmuxRun) parseList(args []string) ([]parsedCmd, error) {
	var out []parsedCmd
	for _, argv := range splitCommands(args) {
		if len(argv) == 0 {
			continue
		}
		pc, err := parseCommand(argv)
		if err != nil {
			return nil, err
		}
		out = append(out, pc)
	}
	return out, nil
}

func parseCommand(argv []string) (parsedCmd, error) {
	name, err := findCommand(argv[0])
	if err != nil {
		if strings.HasPrefix(err.Error(), "unknown") {
			logUnknown("tmux", argv[0])
		}
		return parsedCmd{}, err
	}
	spec := commandSpecs[name]
	if spec == nil {
		// A real tmux command the shim doesn't serve.
		logUnknown("tmux", name)
		return parsedCmd{}, errf("unknown command: %s", name)
	}
	a, err := getopt(spec, argv[1:])
	if err != nil {
		return parsedCmd{}, err
	}
	return parsedCmd{spec: spec, args: a}, nil
}

// getopt is args_parse: flags first (combined, values attached or next),
// "--" ends them, a lone "-" is an argument.
func getopt(spec *cmdSpec, argv []string) (*cmdArgs, error) {
	a := &cmdArgs{name: spec.name, flags: map[byte][]string{}}
	i := 0
	for i < len(argv) {
		s := argv[i]
		if s == "--" {
			i++
			break
		}
		if len(s) < 2 || s[0] != '-' {
			break
		}
		i++
		for j := 1; j < len(s); j++ {
			f := s[j]
			k := strings.IndexByte(spec.flags, f)
			if k < 0 || f == ':' {
				return nil, errf("command %s: unknown flag -%c", spec.name, f)
			}
			if k+1 < len(spec.flags) && spec.flags[k+1] == ':' {
				val := s[j+1:]
				if val == "" {
					if i >= len(argv) {
						return nil, errf("command %s: -%c expects an argument", spec.name, f)
					}
					val = argv[i]
					i++
				}
				a.flags[f] = append(a.flags[f], val)
				break
			}
			a.flags[f] = append(a.flags[f], "")
		}
	}
	a.args = argv[i:]
	if len(a.args) < spec.min {
		return nil, errf("command %s: too few arguments (need at least %d)", spec.name, spec.min)
	}
	if spec.max >= 0 && len(a.args) > spec.max {
		return nil, errf("command %s: too many arguments (need at most %d)", spec.name, spec.max)
	}
	return a, nil
}

// ParseTmux checks a tmux argv the way the shim would before running it:
// nil when every command is one the shim serves with valid flags. The
// contract test uses it.
func ParseTmux(args []string) error {
	r := &tmuxRun{}
	i := 0
	for i < len(args) {
		a := args[i]
		if a == "--" {
			i++
			break
		}
		if len(a) < 2 || a[0] != '-' {
			break
		}
		i++
		if last := a[len(a)-1]; len(a) == 2 && strings.IndexByte("LSfTc", last) >= 0 {
			i++
		}
	}
	if i >= len(args) {
		return nil
	}
	_, err := r.parseList(args[i:])
	return err
}
