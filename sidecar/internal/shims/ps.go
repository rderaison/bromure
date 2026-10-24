package shims

import (
	"fmt"
	"io"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/panes"
)

// The ps shim: procps-ng 4 output for the forms Bromure AC runs on a
// guest (CodingTasks.swift floor probe, AgentPaneProbe, PaneTypeGuard,
// AgentSessionEngine, RegistrationLaunch, the .bashrc's type-when-up),
// answered from the pane host's process table. There is no real procps on
// Windows to fall back to, so an unknown form prints what it can (the
// default columns) and never fails harder than procps would.
//
// Deviations from procps, on purpose:
//   - rows are in start order, not pid order (Windows pids aren't
//     monotonic, and the client takes "the first" foreground process as
//     the agent);
//   - console helpers (conhost, OpenConsole, winpty-agent) are left out;
//   - args shows argv[0] as its base name without .exe ("bash --login",
//     not "C:\Program Files\Git\usr\bin\bash.exe --login"), so the client's
//     shell filters (`^-?([^ ]*/)?(bash|sh|…)( |$)`) see what they see on
//     Linux;
//   - the foreground process group (stat "+", pgid == tpgid) is the pane
//     host's Proc.Foreground set (the agent and its descendants, as on Linux
//     where an agent's tool children share its group), led by its oldest
//     member. When nothing is marked, the shim walks from the window's root
//     through shells to the newest child that isn't one.
//   - pgid/tpgid/sid are made up from that; every process belongs to the
//     one user (uid 1000, as the guest's).

// psCol is one output column.
type psCol struct {
	key    string
	header string
	width  int
	right  bool
	val    func(p *psProc) string
}

// psProc is a row: the pane host's process plus what ps derives.
type psProc struct {
	panes.Proc
	args   string
	comm   string
	tty    string
	stat   string
	pgid   int
	tpgid  int
	leader bool
}

var helperExes = map[string]bool{"conhost": true, "openconsole": true, "winpty-agent": true, "winpty": true}

var shellExes = map[string]bool{
	"bash": true, "sh": true, "zsh": true, "dash": true, "fish": true, "login": true,
	"cmd": true, "pwsh": true, "powershell": true, "tmux": true, "bromure-sidecar": true,
}

func isShellExe(e string) bool { return shellExes[strings.ToLower(e)] }

// RunPs runs one ps command line (argv without "ps").
func RunPs(c panes.Client, args []string, stdout, stderr io.Writer) int {
	logx.Quiet()
	opts, err := parsePsArgs(args)
	if err != nil {
		fmt.Fprint(stderr, err.Error())
		return 1
	}
	if c == nil {
		return 1
	}
	table, err := c.ProcTable()
	if err != nil {
		return 1
	}
	procs := buildRows(table, time.Now())

	var sel []*psProc
	switch {
	case opts.all:
		sel = procs
	case len(opts.pids) > 0 || len(opts.ttys) > 0 || len(opts.cmds) > 0 || opts.ppids != nil:
		ttyKnown := false
		for _, p := range procs {
			if opts.match(p) {
				sel = append(sel, p)
			}
		}
		if len(opts.ttys) > 0 {
			for _, p := range procs {
				for _, t := range opts.ttys {
					if p.tty == t {
						ttyKnown = true
					}
				}
			}
			if !ttyKnown && len(sel) == 0 && !ttyOfAWindow(c, opts.ttys) {
				fmt.Fprint(stderr, "error: TTY could not be found\n"+psUsage)
				return 1
			}
		}
	default:
		// procps: this terminal's processes. Inside a window that is the
		// window's; elsewhere every window's (there's no other terminal).
		w := os.Getenv("BROMURE_WINDOW")
		for _, p := range procs {
			if w == "" || strconv.Itoa(p.Window) == w {
				sel = append(sel, p)
			}
		}
	}

	cols := opts.cols
	if len(cols) == 0 {
		cols = defaultCols(opts)
	}
	var b strings.Builder
	if !opts.noHeaders {
		any := false
		for _, c := range cols {
			if c.header != "" {
				any = true
			}
		}
		if any {
			writeRow(&b, cols, func(c psCol) string { return c.header })
		}
	}
	for _, p := range sel {
		p := p
		writeRow(&b, cols, func(c psCol) string { return c.val(p) })
	}
	io.WriteString(stdout, b.String())
	if len(sel) == 0 {
		return 1
	}
	return 0
}

func ttyOfAWindow(c panes.Client, ttys []string) bool {
	ws, err := c.List(true)
	if err != nil {
		return false
	}
	for _, w := range ws {
		for _, t := range ttys {
			if strings.TrimPrefix(w.TTY, "/dev/") == t {
				return true
			}
		}
	}
	return false
}

func writeRow(b *strings.Builder, cols []psCol, cell func(psCol) string) {
	for i, c := range cols {
		v := cell(c)
		last := i == len(cols)-1
		if i > 0 {
			b.WriteByte(' ')
		}
		n := len([]rune(v))
		switch {
		case c.right && n < c.width:
			b.WriteString(strings.Repeat(" ", c.width-n) + v)
		case !c.right && !last && n < c.width:
			b.WriteString(v + strings.Repeat(" ", c.width-n))
		default:
			b.WriteString(v)
		}
	}
	b.WriteByte('\n')
}

// --- rows -------------------------------------------------------------------------

// normArgs is args with argv[0] reduced to its base name sans extension.
func normArgs(args, exe string) string {
	s := strings.TrimSpace(args)
	if s == "" {
		return exe
	}
	var first, rest string
	switch {
	case s[0] == '"':
		end := strings.IndexByte(s[1:], '"')
		if end < 0 {
			first, rest = s[1:], ""
		} else {
			first, rest = s[1:1+end], s[2+end:]
		}
	default:
		cut := -1
		if exe != "" {
			low := strings.ToLower(s)
			for _, ext := range []string{".exe", ".cmd", ".bat", ".com", ""} {
				if i := strings.Index(low, strings.ToLower(exe)+ext); i >= 0 {
					e := i + len(exe) + len(ext)
					if e == len(s) || s[e] == ' ' || s[e] == '\t' {
						cut = e
						break
					}
				}
			}
		}
		if cut < 0 || strings.IndexAny(s[:cut], `\/:`) < 0 {
			cut = strings.IndexAny(s, " \t")
			if cut < 0 {
				cut = len(s)
			}
		}
		first, rest = s[:cut], s[cut:]
	}
	rest = strings.TrimLeft(rest, " \t")
	base := first
	if i := strings.LastIndexAny(base, `\/`); i >= 0 {
		base = base[i+1:]
	}
	low := strings.ToLower(base)
	for _, ext := range []string{".exe", ".cmd", ".bat", ".com"} {
		if strings.HasSuffix(low, ext) {
			base = base[:len(base)-len(ext)]
			break
		}
	}
	if base == "" {
		base = exe
	}
	if rest == "" {
		return base
	}
	return base + " " + rest
}

func exeOf(p panes.Proc) string {
	if p.Exe != "" {
		e := p.Exe
		if i := strings.LastIndexAny(e, `\/`); i >= 0 {
			e = e[i+1:]
		}
		low := strings.ToLower(e)
		for _, ext := range []string{".exe", ".cmd", ".bat", ".com"} {
			if strings.HasSuffix(low, ext) {
				e = e[:len(e)-len(ext)]
				break
			}
		}
		return e
	}
	f := strings.Fields(normArgs(p.Args, ""))
	if len(f) == 0 {
		return "?"
	}
	return strings.TrimPrefix(f[0], "-")
}

// buildRows turns the pane host's table into ps rows: helpers dropped,
// args normalized, the foreground group and session leaders worked out,
// sorted by start.
func buildRows(table []panes.Proc, now time.Time) []*psProc {
	var rows []*psProc
	byPID := map[int]*psProc{}
	for _, p := range table {
		e := exeOf(p)
		if helperExes[strings.ToLower(e)] {
			continue
		}
		r := &psProc{Proc: p, comm: e, tty: strings.TrimPrefix(p.TTY, "/dev/")}
		r.args = normArgs(p.Args, e)
		if r.tty == "" {
			r.tty = "?"
		}
		r.pgid = p.PID
		r.tpgid = -1
		rows = append(rows, r)
		byPID[p.PID] = r
	}
	sort.SliceStable(rows, func(i, j int) bool {
		a, b := rows[i], rows[j]
		if !a.StartedAt.Equal(b.StartedAt) {
			return a.StartedAt.Before(b.StartedAt)
		}
		return a.PID < b.PID
	})
	children := map[int][]*psProc{}
	for _, r := range rows {
		if par, ok := byPID[r.PPID]; ok && par != r {
			children[r.PPID] = append(children[r.PPID], r)
		}
	}

	byWin := map[int][]*psProc{}
	for _, r := range rows {
		if r.tty != "?" {
			byWin[r.Window] = append(byWin[r.Window], r)
		}
	}
	for _, list := range byWin {
		inWin := map[int]bool{}
		for _, r := range list {
			inWin[r.PID] = true
		}
		var root *psProc
		for _, r := range list { // the oldest process whose parent is outside
			if !inWin[r.PPID] || r.PPID == r.PID {
				root = r
				break
			}
		}
		if root != nil {
			root.leader = true
		}
		// The pane host's foreground group (its leader and descendants)
		// when it marked one; the earliest-started member leads it.
		group := map[int]bool{}
		var lead *psProc
		for _, r := range list {
			if r.Foreground {
				group[r.PID] = true
				if lead == nil {
					lead = r // list is in start order
				}
			}
		}
		if lead != nil {
			for _, r := range list {
				r.tpgid = lead.PID
				if group[r.PID] {
					r.pgid = lead.PID
				}
			}
			continue
		}
		if root != nil {
			lead = root
			for isShellExe(lead.comm) {
				var next *psProc
				for _, ch := range children[lead.PID] {
					if inWin[ch.PID] {
						next = ch // newest wins (children are in start order)
					}
				}
				if next == nil {
					break
				}
				lead = next
			}
		}
		if lead == nil {
			continue
		}
		var mark func(p *psProc)
		mark = func(p *psProc) {
			if group[p.PID] {
				return
			}
			group[p.PID] = true
			for _, ch := range children[p.PID] {
				if inWin[ch.PID] {
					mark(ch)
				}
			}
		}
		mark(lead)
		for _, r := range list {
			r.tpgid = lead.PID
			if group[r.PID] {
				r.pgid = lead.PID
			}
		}
	}
	for _, r := range rows {
		st := "S"
		if r.leader {
			st += "s"
		}
		if r.tpgid > 0 && r.pgid == r.tpgid {
			st += "+"
		}
		r.stat = st
	}
	return rows
}

// --- columns ----------------------------------------------------------------------

func etime(d time.Duration) string {
	s := int(d.Seconds())
	if s < 0 {
		s = 0
	}
	days, s := s/86400, s%86400
	h, s := s/3600, s%3600
	m, s := s/60, s%60
	switch {
	case days > 0:
		return fmt.Sprintf("%d-%02d:%02d:%02d", days, h, m, s)
	case h > 0:
		return fmt.Sprintf("%02d:%02d:%02d", h, m, s)
	}
	return fmt.Sprintf("%02d:%02d", m, s)
}

func since(p *psProc) time.Duration {
	if p.StartedAt.IsZero() {
		return 0
	}
	return time.Since(p.StartedAt)
}

func stime(p *psProc) string {
	if p.StartedAt.IsZero() {
		return "00:00"
	}
	if time.Since(p.StartedAt) > 24*time.Hour {
		return p.StartedAt.Format("Jan02")
	}
	return p.StartedAt.Format("15:04")
}

var psColumns = map[string]psCol{
	"pid":        {header: "PID", width: 7, right: true, val: func(p *psProc) string { return itoa(p.PID) }},
	"ppid":       {header: "PPID", width: 7, right: true, val: func(p *psProc) string { return itoa(p.PPID) }},
	"pgid":       {header: "PGID", width: 7, right: true, val: func(p *psProc) string { return itoa(p.pgid) }},
	"pgrp":       {header: "PGRP", width: 7, right: true, val: func(p *psProc) string { return itoa(p.pgid) }},
	"tpgid":      {header: "TPGID", width: 7, right: true, val: func(p *psProc) string { return itoa(p.tpgid) }},
	"sid":        {header: "SID", width: 7, right: true, val: func(p *psProc) string { return itoa(p.pgid) }},
	"sess":       {header: "SESS", width: 7, right: true, val: func(p *psProc) string { return itoa(p.pgid) }},
	"stat":       {header: "STAT", width: 4, val: func(p *psProc) string { return p.stat }},
	"s":          {header: "S", width: 1, val: func(p *psProc) string { return "S" }},
	"state":      {header: "S", width: 1, val: func(p *psProc) string { return "S" }},
	"tty":        {header: "TT", width: 8, val: func(p *psProc) string { return p.tty }},
	"tt":         {header: "TT", width: 8, val: func(p *psProc) string { return p.tty }},
	"tname":      {header: "TTY", width: 8, val: func(p *psProc) string { return p.tty }},
	"etimes":     {header: "ELAPSED", width: 7, right: true, val: func(p *psProc) string { return itoa(int(since(p).Seconds())) }},
	"etime":      {header: "ELAPSED", width: 11, right: true, val: func(p *psProc) string { return etime(since(p)) }},
	"time":       {header: "TIME", width: 8, right: true, val: func(*psProc) string { return "00:00:00" }},
	"cputime":    {header: "TIME", width: 8, right: true, val: func(*psProc) string { return "00:00:00" }},
	"times":      {header: "TIME", width: 7, right: true, val: func(*psProc) string { return "0" }},
	"args":       {header: "COMMAND", width: 27, val: func(p *psProc) string { return p.args }},
	"command":    {header: "COMMAND", width: 27, val: func(p *psProc) string { return p.args }},
	"cmd":        {header: "CMD", width: 27, val: func(p *psProc) string { return p.args }},
	"comm":       {header: "COMMAND", width: 15, val: func(p *psProc) string { return trunc(p.comm, 15) }},
	"ucmd":       {header: "CMD", width: 15, val: func(p *psProc) string { return trunc(p.comm, 15) }},
	"ucomm":      {header: "COMMAND", width: 15, val: func(p *psProc) string { return trunc(p.comm, 15) }},
	"fname":      {header: "COMMAND", width: 8, val: func(p *psProc) string { return trunc(p.comm, 8) }},
	"user":       {header: "USER", width: 8, val: func(*psProc) string { return trunc(userName(), 8) }},
	"euser":      {header: "EUSER", width: 8, val: func(*psProc) string { return trunc(userName(), 8) }},
	"ruser":      {header: "RUSER", width: 8, val: func(*psProc) string { return trunc(userName(), 8) }},
	"uname":      {header: "USER", width: 8, val: func(*psProc) string { return trunc(userName(), 8) }},
	"uid":        {header: "UID", width: 5, right: true, val: func(*psProc) string { return "1000" }},
	"euid":       {header: "EUID", width: 5, right: true, val: func(*psProc) string { return "1000" }},
	"ruid":       {header: "RUID", width: 5, right: true, val: func(*psProc) string { return "1000" }},
	"lstart":     {header: "STARTED", width: 24, val: func(p *psProc) string { return p.StartedAt.Format("Mon Jan _2 15:04:05 2006") }},
	"start":      {header: "STARTED", width: 8, val: func(p *psProc) string { return p.StartedAt.Format("15:04:05") }},
	"stime":      {header: "STIME", width: 5, val: stime},
	"start_time": {header: "START", width: 5, val: stime},
	"%cpu":       {header: "%CPU", width: 4, right: true, val: func(*psProc) string { return "0.0" }},
	"pcpu":       {header: "%CPU", width: 4, right: true, val: func(*psProc) string { return "0.0" }},
	"%mem":       {header: "%MEM", width: 4, right: true, val: func(*psProc) string { return "0.0" }},
	"pmem":       {header: "%MEM", width: 4, right: true, val: func(*psProc) string { return "0.0" }},
	"c":          {header: "C", width: 2, right: true, val: func(*psProc) string { return "0" }},
	"vsz":        {header: "VSZ", width: 6, right: true, val: func(*psProc) string { return "0" }},
	"rss":        {header: "RSS", width: 5, right: true, val: func(*psProc) string { return "0" }},
	"nlwp":       {header: "NLWP", width: 4, right: true, val: func(*psProc) string { return "1" }},
	"ni":         {header: "NI", width: 3, right: true, val: func(*psProc) string { return "0" }},
	"pri":        {header: "PRI", width: 3, right: true, val: func(*psProc) string { return "19" }},
	"wchan":      {header: "WCHAN", width: 6, val: func(*psProc) string { return "-" }},
}

func trunc(s string, n int) string {
	r := []rune(s)
	if len(r) > n {
		return string(r[:n])
	}
	return s
}

func col(key string) psCol {
	c := psColumns[key]
	c.key = key
	return c
}

func defaultCols(o *psOpts) []psCol {
	switch {
	case o.bsdU:
		aux := []psCol{col("user"), col("pid"), col("%cpu"), col("%mem"), col("vsz"), col("rss"), col("tty"), col("stat"), col("start_time"), col("times"), col("command")}
		aux[6].header = "TTY"
		aux[9].header, aux[9].width, aux[9].val = "TIME", 6, func(*psProc) string { return "0:00" }
		return aux
	case o.full:
		cs := []psCol{col("user"), col("pid"), col("ppid"), col("c"), col("stime"), col("tname"), col("time"), col("cmd")}
		cs[0].header = "UID"
		return cs
	case o.bsd:
		return []psCol{col("pid"), col("tty"), col("stat"), col("time"), col("command")}
	}
	return []psCol{col("pid"), col("tname"), col("time"), col("ucmd")}
}

// --- arguments --------------------------------------------------------------------

const psUsage = "\nUsage:\n ps [options]\n\n Try 'ps --help <simple|list|output|threads|misc|all>'\n  or 'ps --help <s|l|o|t|m|a>'\n for additional help text.\n\nFor more details see ps(1).\n"

type psOpts struct {
	all       bool
	pids      map[int]bool
	ppids     map[int]bool
	ttys      []string
	cmds      map[string]bool
	cols      []psCol
	noHeaders bool
	full      bool
	bsd       bool
	bsdU      bool
}

func (o *psOpts) match(p *psProc) bool {
	if o.pids[p.PID] || o.ppids[p.PPID] || o.cmds[p.comm] {
		return true
	}
	for _, t := range o.ttys {
		if p.tty == t {
			return true
		}
	}
	return false
}

func psErr(msg string) error { return fmt.Errorf("error: %s\n%s", msg, psUsage) }

func (o *psOpts) addFormat(spec string) error {
	// Comma or blank separated; name=header renames (an empty header
	// hides it — no header line when every header is empty).
	for _, item := range strings.FieldsFunc(spec, func(r rune) bool { return r == ',' || r == ' ' || r == '\t' }) {
		name, header, renamed := strings.Cut(item, "=")
		key := strings.ToLower(name)
		c, ok := psColumns[key]
		if !ok {
			return psErr(fmt.Sprintf("unknown user-defined format specifier \"%s\"", name))
		}
		c.key = key
		if renamed {
			c.header = header
			if len(header) > c.width {
				c.width = len(header)
			}
		}
		o.cols = append(o.cols, c)
	}
	return nil
}

func (o *psOpts) addList(kind, v string) error {
	for _, item := range strings.FieldsFunc(v, func(r rune) bool { return r == ',' || r == ' ' }) {
		switch kind {
		case "p", "q", "ppid":
			n, err := strconv.Atoi(item)
			if err != nil || n < 0 {
				return psErr("process ID list syntax error")
			}
			if kind == "ppid" {
				if o.ppids == nil {
					o.ppids = map[int]bool{}
				}
				o.ppids[n] = true
			} else {
				if o.pids == nil {
					o.pids = map[int]bool{}
				}
				o.pids[n] = true
			}
		case "t":
			o.ttys = append(o.ttys, strings.TrimPrefix(item, "/dev/"))
		case "C":
			if o.cmds == nil {
				o.cmds = map[string]bool{}
			}
			o.cmds[item] = true
		}
	}
	return nil
}

func parsePsArgs(args []string) (*psOpts, error) {
	o := &psOpts{}
	for i := 0; i < len(args); i++ {
		a := args[i]
		next := func() (string, error) {
			if i+1 >= len(args) {
				return "", psErr("list of process IDs must follow " + a)
			}
			i++
			return args[i], nil
		}
		switch {
		case strings.HasPrefix(a, "--"):
			name, val, hasVal := strings.Cut(a[2:], "=")
			takes := map[string]string{"pid": "p", "ppid": "ppid", "tty": "t", "format": "o", "sort": "", "width": "", "cols": "", "columns": "", "lines": "", "rows": "", "user": "", "User": "", "group": "", "Group": "", "sid": "", "quick-pid": "q"}
			if kind, ok := takes[name]; ok {
				if !hasVal {
					v, err := next()
					if err != nil {
						return nil, err
					}
					val = v
				}
				switch kind {
				case "o":
					if err := o.addFormat(val); err != nil {
						return nil, err
					}
				case "":
				default:
					if err := o.addList(kind, val); err != nil {
						return nil, err
					}
				}
				continue
			}
			switch name {
			case "no-headers", "no-heading":
				o.noHeaders = true
			case "deselect", "forest", "headers", "cumulative", "info", "version", "help":
			default:
				return nil, psErr("unknown gnu long option")
			}
		case strings.HasPrefix(a, "-") && len(a) > 1:
			for j := 1; j < len(a); j++ {
				f := a[j]
				val := func() (string, error) {
					if j+1 < len(a) {
						v := a[j+1:]
						j = len(a)
						return v, nil
					}
					j = len(a)
					return next()
				}
				switch f {
				case 'A', 'e':
					o.all = true
				case 'a', 'd', 'N', 'H', 'L', 'T', 'M', 'Z', 'c', 'y', 'j', 'l', 'F', 'P', 'x':
					// accepted; they change nothing here
				case 'f':
					o.full = true
				case 'w':
				case 'o', 'O':
					v, err := val()
					if err != nil {
						return nil, err
					}
					if err := o.addFormat(v); err != nil {
						return nil, err
					}
				case 'p', 'q', 't', 'C':
					v, err := val()
					if err != nil {
						return nil, err
					}
					if err := o.addList(string(f), v); err != nil {
						return nil, err
					}
				case 'u', 'U', 'g', 'G', 's':
					if _, err := val(); err != nil {
						return nil, err
					}
					o.all = true // one user here: every process is theirs
				default:
					return nil, psErr("unsupported SysV option")
				}
			}
		default:
			// BSD-style letters ("aux", "ax", "ww", "o", "p 123").
			for j := 0; j < len(a); j++ {
				switch a[j] {
				case 'a', 'x', 'g', 'r':
					if a[j] == 'x' || a[j] == 'a' {
						o.all = true
					}
					o.bsd = true
				case 'u':
					o.bsdU = true
				case 'w', 'e', 'f', 'h', 'c', 'j', 'l', 's', 'v', 'S', 'm', 'n', 'H', 'L', 'X':
					if a[j] == 'h' {
						o.noHeaders = true
					}
				case 'o', 'O':
					v, err := next()
					if err != nil {
						return nil, err
					}
					if err := o.addFormat(v); err != nil {
						return nil, err
					}
				case 'p', 'q':
					v, err := next()
					if err != nil {
						return nil, err
					}
					if err := o.addList("p", v); err != nil {
						return nil, err
					}
				case 't':
					v, err := next()
					if err != nil {
						return nil, err
					}
					if err := o.addList("t", v); err != nil {
						return nil, err
					}
				default:
					if a[j] >= '0' && a[j] <= '9' {
						if err := o.addList("p", a[j:]); err != nil {
							return nil, err
						}
						j = len(a)
						continue
					}
					return nil, psErr("unsupported option (BSD syntax)")
				}
			}
		}
	}
	return o, nil
}

// ParsePs checks a ps argv the way the shim would (for the contract
// test): nil when the form is understood.
func ParsePs(args []string) error {
	_, err := parsePsArgs(args)
	return err
}
