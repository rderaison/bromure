package panes

import (
	"sort"
	"strings"
	"time"
)

// procInfo is one process as the OS reports it.
type procInfo struct {
	pid, ppid int
	exe       string // base name, no extension
	args      string // POSIX-ish: argv[0]'s base name, then the rest verbatim
	start     time.Time
}

// shells are skipped when looking for a window's foreground program (the
// client's awk filters skip the same names).
var shells = map[string]bool{
	"bash": true, "sh": true, "zsh": true, "dash": true, "fish": true, "login": true,
	"pwsh": true, "powershell": true, "cmd": true,
}

// helpers never show in the table (ConPTY's own console hosts).
var helpers = map[string]bool{"conhost": true, "openconsole": true}

func isShell(exe string) bool  { return shells[strings.ToLower(exe)] }
func isHelper(exe string) bool { return helpers[strings.ToLower(exe)] }

// ProcTable lists every live window's processes (the ps shim's source).
func (h *Host) ProcTable() ([]Proc, error) { return h.procTableFor(nil), nil }

func (h *Host) procTableFor(only []*window) []Proc {
	h.mu.Lock()
	var ws []*window
	if only != nil {
		ws = only
	} else {
		for _, w := range h.windows {
			ws = append(ws, w)
		}
	}
	h.mu.Unlock()
	var live []*window
	for _, w := range ws {
		w.mu.Lock()
		if w.alive {
			live = append(live, w)
		}
		w.mu.Unlock()
	}
	if len(live) == 0 {
		return nil
	}
	sort.Slice(live, func(i, j int) bool { return live[i].index < live[j].index })
	members := windowProcs(live)
	var out []Proc
	for _, w := range live {
		out = append(out, buildTable(w.index, w.tty(), w.proc.Pid(), members[w])...)
	}
	return out
}

// buildTable orders a window's processes depth-first from its root child
// (children by start time; orphans after) and marks the foreground: the
// root, or when it is a shell, the latest program run from the shell(s)
// (the deepest non-shell below shells only) — and everything under it (its
// process group, on a real tty).
func buildTable(index int, tty string, root int, members []*procInfo) []Proc {
	by := map[int]*procInfo{}
	for _, p := range members {
		if !isHelper(p.exe) {
			by[p.pid] = p
		}
	}
	if len(by) == 0 {
		return nil
	}
	kids := map[int][]*procInfo{}
	var tops []*procInfo
	for _, p := range by {
		if _, ok := by[p.ppid]; ok && p.pid != root && p.ppid != p.pid {
			kids[p.ppid] = append(kids[p.ppid], p)
		} else {
			tops = append(tops, p)
		}
	}
	older := func(s []*procInfo) {
		sort.Slice(s, func(i, j int) bool {
			if !s[i].start.Equal(s[j].start) {
				return s[i].start.Before(s[j].start)
			}
			return s[i].pid < s[j].pid
		})
	}
	for _, s := range kids {
		older(s)
	}
	older(tops)
	// The root first, then orphans (their parent left the tree).
	for i, p := range tops {
		if p.pid == root && i > 0 {
			copy(tops[1:i+1], tops[:i])
			tops[0] = p
			break
		}
	}

	fg := tops[0]
	if r, ok := by[root]; ok {
		fg = r
	}
	if isShell(fg.exe) {
		// The latest-started non-shell whose ancestors in the tree are all
		// shells (its parent chain may be cut: an MSYS exec leaves the
		// program's parent stub outside the job). Else the latest shell.
		var best, bestShell *procInfo
		for _, p := range by {
			if isShell(p.exe) {
				if bestShell == nil || later(p, bestShell) {
					bestShell = p
				}
				continue
			}
			top := true
			for a, ok := by[p.ppid]; ok && a.pid != p.pid; a, ok = by[a.ppid] {
				if !isShell(a.exe) {
					top = false
					break
				}
				if a.pid == root {
					break
				}
			}
			if top && (best == nil || later(p, best)) {
				best = p
			}
		}
		if best != nil {
			fg = best
		} else if bestShell != nil {
			fg = bestShell
		}
	}
	inFg := map[int]bool{}
	var mark func(p *procInfo)
	mark = func(p *procInfo) {
		inFg[p.pid] = true
		for _, k := range kids[p.pid] {
			mark(k)
		}
	}
	mark(fg)

	var out []Proc
	seen := map[int]bool{}
	var walk func(p *procInfo)
	walk = func(p *procInfo) {
		if seen[p.pid] {
			return
		}
		seen[p.pid] = true
		out = append(out, Proc{
			PID: p.pid, PPID: p.ppid, Window: index, TTY: tty, Args: p.args, Exe: p.exe,
			StartedAt: p.start, Foreground: inFg[p.pid],
		})
		for _, k := range kids[p.pid] {
			walk(k)
		}
	}
	for _, t := range tops {
		walk(t)
	}
	return out
}

func later(a, b *procInfo) bool {
	if !a.start.Equal(b.start) {
		return a.start.After(b.start)
	}
	return a.pid > b.pid
}

// posixArgs rewrites a Windows command line for ps: argv[0] becomes its
// base name without extension (`"C:\Program Files\nodejs\node.exe" x.js`
// is `node x.js`), the rest is kept as is.
func posixArgs(cmdline string) string {
	s := strings.TrimLeft(cmdline, " \t")
	var first, rest string
	if strings.HasPrefix(s, `"`) {
		if i := strings.IndexByte(s[1:], '"'); i >= 0 {
			first, rest = s[1:i+1], s[i+2:]
		} else {
			first = s[1:]
		}
	} else if i := strings.IndexAny(s, " \t"); i >= 0 {
		first, rest = s[:i], s[i:]
	} else {
		first = s
	}
	rest = strings.TrimLeft(rest, " \t")
	b := exeBase(first)
	if rest == "" {
		return b
	}
	return b + " " + rest
}
