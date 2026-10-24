package shims

import (
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/rderaison/bromure/sidecar/internal/panes"
	"github.com/rderaison/bromure/sidecar/internal/vpath"
)

// commandSpecs are the commands the shim serves, with tmux 3.4's getopt
// strings and argument counts.
var commandSpecs map[string]*cmdSpec

func init() {
	specs := []*cmdSpec{
		{name: "display-message", flags: "aCc:d:lINpt:F:v", min: 0, max: 1, run: cmdDisplay},
		{name: "list-windows", flags: "F:f:at:", min: 0, max: 0, run: cmdListWindows},
		{name: "list-panes", flags: "aF:f:st:", min: 0, max: 0, run: cmdListPanes},
		{name: "list-clients", flags: "F:f:t:", min: 0, max: 0, run: cmdListClients},
		{name: "list-sessions", flags: "F:f:", min: 0, max: 0, run: cmdListSessions},
		{name: "capture-pane", flags: "ab:CeE:JNpPqS:Tt:", min: 0, max: 0, run: cmdCapture},
		{name: "send-keys", flags: "c:FHKlMN:Rt:X", min: 0, max: -1, run: cmdSendKeys},
		{name: "load-buffer", flags: "b:t:w", min: 1, max: 1, run: cmdLoadBuffer},
		{name: "set-buffer", flags: "ab:t:n:w", min: 0, max: 1, run: cmdSetBuffer},
		{name: "paste-buffer", flags: "db:prS:s:t:", min: 0, max: 0, run: cmdPasteBuffer},
		{name: "delete-buffer", flags: "b:", min: 0, max: 0, run: cmdDeleteBuffer},
		{name: "set-option", flags: "aFgopqst:uUw", min: 1, max: 2, run: cmdSetOption},
		{name: "set-window-option", flags: "aFgoqt:u", min: 1, max: 2, run: cmdSetOption},
		{name: "show-options", flags: "AgHpqst:vw", min: 0, max: 1, run: cmdShowOptions},
		{name: "show-window-options", flags: "gvt:", min: 0, max: 1, run: cmdShowOptions},
		{name: "select-window", flags: "lnpTt:", min: 0, max: 0, run: cmdSelectWindow},
		{name: "kill-window", flags: "at:", min: 0, max: 0, run: cmdKillWindow},
		{name: "kill-session", flags: "aCt:", min: 0, max: 0, run: cmdKillSession},
		{name: "has-session", flags: "t:", min: 0, max: 0, run: cmdHasSession},
		{name: "resize-window", flags: "aADLRt:Ux:y:", min: 0, max: 1, run: cmdResizeWindow},
		{name: "refresh-client", flags: "A:B:cC:Df:r:F:l:LRSt:U", min: 0, max: 1, run: cmdRefreshClient},
		{name: "new-window", flags: "abc:de:F:kn:PSt:", min: 0, max: -1, run: cmdNewWindow},
		{name: "new-session", flags: "Ac:dDe:EF:f:n:Ps:t:x:Xy:", min: 0, max: -1, run: cmdNewSession},
		{name: "attach-session", flags: "c:dEf:rt:x", min: 0, max: 0, run: cmdAttach},
		{name: "start-server", flags: "", min: 0, max: 0, run: func(*tmuxRun, *cmdArgs) error { return nil }},
	}
	commandSpecs = map[string]*cmdSpec{}
	for _, s := range specs {
		commandSpecs[s.name] = s
	}
}

// --- display-message --------------------------------------------------------

const displayTemplate = "[#{session_name}] #{window_index}:#{window_name}, current pane #{pane_index} - (%H:%M %d-%b-%y)"

func cmdDisplay(r *tmuxRun, a *cmdArgs) error {
	ctx, err := r.targetCanFail(a)
	if err != nil {
		return err
	}
	if c, ok := a.get('c'); ok {
		cl, err := r.findClient(c)
		if err != nil {
			return err
		}
		ctx.client = cl
	}
	if a.has('a') {
		for _, n := range variableNames() {
			if v, ok := r.lookup(n, ctx); ok {
				r.println(n + "=" + v)
			}
		}
		return nil
	}
	tmpl := displayTemplate
	if f, ok := a.get('F'); ok {
		tmpl = f
	} else if len(a.args) > 0 {
		tmpl = a.args[0]
	}
	if !a.has('p') {
		return nil // a status-line message: nobody sees it here
	}
	var msg string
	if a.has('l') {
		msg = tmpl
	} else {
		msg = r.expand(strftime(tmpl, time.Now()), ctx)
	}
	r.println(msg)
	return nil
}

// --- list-* -------------------------------------------------------------------

const (
	lswTemplate = "#{window_index}: #{window_name}#{window_raw_flags} (#{window_panes} panes) [#{window_width}x#{window_height}] [layout #{window_layout}] #{window_id}#{?window_active, (active),}"
	lspTemplate = "#{pane_index}: [#{pane_width}x#{pane_height}] [history #{history_size}/#{history_limit}, #{history_bytes} bytes] #{pane_id}#{?pane_active, (active),}#{?pane_dead, (dead),}"
	lscTemplate = "#{client_name}: #{session_name} [#{client_width}x#{client_height} #{client_termname}] #{?client_flags,(,}#{client_flags}#{?client_flags,),}"
	lsTemplate  = "#{session_name}: #{session_windows} windows (created #{t:session_created})#{?session_attached, (attached),}"
)

func (r *tmuxRun) filterOK(a *cmdArgs, ctx *fmtCtx) bool {
	f, ok := a.get('f')
	return !ok || formatTrue(r.expand(f, ctx))
}

func cmdListWindows(r *tmuxRun, a *cmdArgs) error {
	t, _ := a.get('t')
	if !a.has('a') {
		if _, err := r.find(t, kindSession); err != nil {
			return err
		}
	}
	ws, err := r.visible()
	if err != nil {
		return err
	}
	tmpl, ok := a.get('F')
	if !ok {
		tmpl = lswTemplate
		if a.has('a') {
			tmpl = "#{session_name}:" + tmpl
		}
	}
	for k := range ws {
		ctx := &fmtCtx{r: r, win: r.view(&ws[k])}
		if r.filterOK(a, ctx) {
			r.println(r.expand(tmpl, ctx))
		}
	}
	return nil
}

func cmdListPanes(r *tmuxRun, a *cmdArgs) error {
	t, _ := a.get('t')
	var list []panes.Window
	tmpl, hasF := a.get('F')
	switch {
	case a.has('a'):
		ws, err := r.visible()
		if err != nil {
			return err
		}
		list = ws
		if !hasF {
			tmpl = "#{session_name}:#{window_index}." + lspTemplate
		}
	case a.has('s'):
		if _, err := r.find(t, kindSession); err != nil {
			return err
		}
		ws, err := r.visible()
		if err != nil {
			return err
		}
		list = ws
		if !hasF {
			tmpl = "#{window_index}." + lspTemplate
		}
	default:
		w, err := r.target(a, kindWindow)
		if err != nil {
			return err
		}
		list = []panes.Window{*w}
		if !hasF {
			tmpl = lspTemplate
		}
	}
	for k := range list {
		ctx := &fmtCtx{r: r, win: r.view(&list[k])}
		if r.filterOK(a, ctx) {
			r.println(r.expand(tmpl, ctx))
		}
	}
	return nil
}

func cmdListClients(r *tmuxRun, a *cmdArgs) error {
	t, hasT := a.get('t')
	if hasT {
		if _, err := r.find(t, kindSession); err != nil {
			return err
		}
	}
	cs, err := r.clients()
	if err != nil {
		return err
	}
	ws, _ := r.all()
	tmpl, ok := a.get('F')
	if !ok {
		tmpl = lscTemplate
	}
	for k := range cs {
		c := cs[k]
		// -t view-…: that grouped session's clients; -t bromure: the
		// clients attached to the session itself.
		if hasT {
			want := strings.TrimPrefix(t, "=")
			if i := strings.IndexByte(want, ':'); i >= 0 {
				want = want[:i]
			}
			if strings.HasPrefix(want, "view-") {
				if c.Session != want {
					continue
				}
			} else if c.Session != "" && c.Session != panes.SessionName {
				continue
			}
		}
		ctx := &fmtCtx{r: r, client: &c}
		for j := range ws {
			if ws[j].Index == c.Window {
				ctx.win = r.view(&ws[j])
			}
		}
		if r.filterOK(a, ctx) {
			r.println(r.expand(tmpl, ctx))
		}
	}
	return nil
}

func cmdListSessions(r *tmuxRun, a *cmdArgs) error {
	if _, err := r.all(); err != nil {
		return err
	}
	tmpl, ok := a.get('F')
	if !ok {
		tmpl = lsTemplate
	}
	ctx := &fmtCtx{r: r, win: r.view(r.sessionCurrent())}
	if r.filterOK(a, ctx) {
		r.println(r.expand(tmpl, ctx))
	}
	return nil
}

func (r *tmuxRun) findClient(name string) (*clientView, error) {
	cs, err := r.clients()
	if err != nil {
		return nil, err
	}
	for k := range cs {
		id, tty := cs[k].ID, cs[k].TTY
		if id == name || (tty != "" && tty == name) || "/dev/"+id == name || id == "/dev/"+name {
			c := cs[k]
			return &c, nil
		}
	}
	return nil, errf("can't find client: %s", name)
}

// --- capture-pane -------------------------------------------------------------

func cmdCapture(r *tmuxRun, a *cmdArgs) error {
	w, err := r.target(a, kindPane)
	if err != nil {
		return err
	}
	opts := panes.CaptureOptions{Join: a.has('J'), Escapes: a.has('e')}
	if s, ok := a.get('S'); ok {
		if s == "-" {
			opts.StartHistory = true
		} else if n, err := strconv.Atoi(s); err == nil {
			opts.Start = &n
		} else {
			n := 0 // tmux: a bad number is 0
			opts.Start = &n
		}
	}
	if e, ok := a.get('E'); ok {
		if e == "-" {
			opts.EndVisible = true
		} else if n, err := strconv.Atoi(e); err == nil {
			opts.End = &n
		} else {
			n := 0
			opts.End = &n
		}
	}
	if a.has('a') {
		s, err := r.c.Screen(w.Index)
		if err == nil && !s.AltScreen {
			if a.has('q') {
				return nil
			}
			return errf("no alternate screen")
		}
	}
	text, err := r.c.Capture(w.Index, opts)
	if err != nil {
		return errf("%s", err.Error())
	}
	if a.has('C') {
		text = captureOctal(text)
	}
	if a.has('p') {
		// tmux prints the lines, each ending in a newline (the pane host
		// already ends each one; tmux adds the last if it's missing).
		if !strings.HasSuffix(text, "\n") {
			text += "\n"
		}
		io.WriteString(r.stdout, text)
		return nil
	}
	name, ok := a.get('b')
	if !ok {
		name = "buffer0"
	}
	return r.c.SetBuffer(name, []byte(text))
}

// captureOctal is -C: non-printable characters as \ooo (newlines kept).
func captureOctal(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == '\n' || (c >= 0x20 && c < 0x7f && c != '\\') {
			b.WriteByte(c)
		} else if c == '\\' {
			b.WriteString(`\\`)
		} else {
			octal(&b, c)
		}
	}
	return b.String()
}

// --- send-keys ----------------------------------------------------------------

func cmdSendKeys(r *tmuxRun, a *cmdArgs) error {
	w, err := r.target(a, kindPane)
	if err != nil {
		return err
	}
	if a.has('X') {
		return errf("not in a mode")
	}
	repeat := 1
	if n, ok := a.get('N'); ok {
		v, err := strconv.Atoi(n)
		if err != nil || v < 1 {
			return errf("repeat count %s", "invalid")
		}
		repeat = v
	}
	if a.has('R') && len(a.args) == 0 {
		return nil
	}
	for rep := 0; rep < repeat; rep++ {
		switch {
		case a.has('H'):
			var buf []byte
			for _, h := range a.args {
				h = strings.TrimPrefix(strings.ToLower(h), "0x")
				if len(h)%2 == 1 {
					h = "0" + h
				}
				b, err := hex.DecodeString(h)
				if err != nil {
					return errf("invalid key: %s", h)
				}
				buf = append(buf, b...)
			}
			if len(buf) > 0 {
				if err := r.c.SendKeys(w.Index, []string{string(buf)}, true); err != nil {
					return errf("%s", err.Error())
				}
			}
		case a.has('l'):
			var text []string
			for _, s := range a.args {
				if s != "" {
					text = append(text, s)
				}
			}
			if len(text) > 0 {
				if err := r.c.SendKeys(w.Index, text, true); err != nil {
					return errf("%s", err.Error())
				}
			}
		default:
			if err := sendMixed(r.c, w.Index, a.args); err != nil {
				return errf("%s", err.Error())
			}
		}
	}
	return nil
}

// sendMixed is send-keys without -l: an argument that is a key name is
// that key; anything else is typed as text (tmux does the same). Runs of
// the same kind go in one call, in order.
func sendMixed(c panes.Client, idx int, args []string) error {
	var run []string
	runKeys := false
	flush := func() error {
		if len(run) == 0 {
			return nil
		}
		err := c.SendKeys(idx, run, !runKeys)
		run = nil
		return err
	}
	for _, s := range args {
		if s == "" {
			continue
		}
		k := IsKeyName(s)
		if k != runKeys && len(run) > 0 {
			if err := flush(); err != nil {
				return err
			}
		}
		runKeys = k
		run = append(run, s)
	}
	return flush()
}

var namedKeys = map[string]bool{}

func init() {
	for _, k := range []string{
		"Enter", "Escape", "Tab", "BTab", "BSpace", "Space", "Up", "Down", "Left", "Right",
		"Home", "End", "IC", "Insert", "DC", "Delete", "NPage", "PageDown", "PgDn",
		"PPage", "PageUp", "PgUp", "KP/", "KP*", "KP-", "KP+", "KP.", "KPEnter",
		"KP0", "KP1", "KP2", "KP3", "KP4", "KP5", "KP6", "KP7", "KP8", "KP9", "Any",
	} {
		namedKeys[strings.ToLower(k)] = true
	}
	for i := 1; i <= 24; i++ {
		namedKeys["f"+strconv.Itoa(i)] = true
	}
}

// IsKeyName is tmux's key_string_lookup_string != KEYC_UNKNOWN for the
// keys a client sends: C-/M-/S- modifiers, ^x, the named keys (any case),
// a single character.
func IsKeyName(s string) bool {
	if strings.HasPrefix(s, "^") && len(s) == 2 {
		return true
	}
	for len(s) > 2 && s[1] == '-' && strings.IndexByte("CcMmSs", s[0]) >= 0 {
		s = s[2:]
	}
	if namedKeys[strings.ToLower(s)] {
		return true
	}
	if strings.HasPrefix(s, "0x") && len(s) > 2 {
		if _, err := strconv.ParseUint(s[2:], 16, 32); err == nil {
			return true
		}
	}
	n := 0
	for range s {
		n++
	}
	return n == 1
}

// --- buffers ------------------------------------------------------------------

func cmdLoadBuffer(r *tmuxRun, a *cmdArgs) error {
	if r.c == nil {
		return r.noServer()
	}
	name, ok := a.get('b')
	if !ok {
		name = "buffer0"
	}
	var data []byte
	var err error
	if a.args[0] == "-" {
		if r.stdin == nil {
			data = nil
		} else if data, err = io.ReadAll(r.stdin); err != nil {
			return errf("%s", err.Error())
		}
	} else {
		p := a.args[0]
		data, err = os.ReadFile(p)
		if err != nil {
			if real, e := vpath.Default().ToReal(p); e == nil {
				data, err = os.ReadFile(real)
			}
		}
		if err != nil {
			return errf("%s: %s", p, "No such file or directory")
		}
	}
	if err := r.c.SetBuffer(name, data); err != nil {
		return errf("%s", err.Error())
	}
	return nil
}

func cmdSetBuffer(r *tmuxRun, a *cmdArgs) error {
	if r.c == nil {
		return r.noServer()
	}
	name, ok := a.get('b')
	if !ok {
		name = "buffer0"
	}
	if len(a.args) == 0 {
		return errf("no data specified")
	}
	if err := r.c.SetBuffer(name, []byte(a.args[0])); err != nil {
		return errf("%s", err.Error())
	}
	return nil
}

func cmdPasteBuffer(r *tmuxRun, a *cmdArgs) error {
	w, err := r.target(a, kindPane)
	if err != nil {
		return err
	}
	name, _ := a.get('b')
	if err := r.c.PasteBuffer(name, w.Index, a.has('p'), a.has('r'), a.has('d')); err != nil {
		switch {
		case errors.Is(err, panes.ErrNoWindow):
			return errf("can't find window: %d", w.Index)
		case name != "" && (errors.Is(err, panes.ErrNoBuffer) || strings.Contains(err.Error(), "buffer")):
			return errf("no buffer %s", name)
		case name == "" && errors.Is(err, panes.ErrNoBuffer):
			return errf("no buffer")
		}
		return errf("%s", err.Error())
	}
	return nil
}

func cmdDeleteBuffer(r *tmuxRun, a *cmdArgs) error {
	if r.c == nil {
		return r.noServer()
	}
	name, ok := a.get('b')
	if !ok {
		name = "buffer0"
	}
	if err := r.c.DeleteBuffer(name); err != nil {
		return errf("unknown buffer: %s", name)
	}
	return nil
}

// --- options --------------------------------------------------------------------

// optScope is where an option lives.
type optScope int

const (
	scopeWindow optScope = iota
	scopeSession
	scopeGlobal
)

func optionScope(a *cmdArgs, name string) optScope {
	switch {
	case a.has('g') || a.has('s'):
		return scopeGlobal
	case a.has('w') || a.has('p') || a.name == "set-window-option" || a.name == "show-window-options":
		return scopeWindow
	}
	if !strings.HasPrefix(name, "@") {
		return scopeWindow // a tmux option: accepted, not stored
	}
	return scopeSession
}

// optTarget is the window a -w/-p option command acts on; the error is
// tmux's own for a CANFAIL target ("no such window: bromure:7").
func (r *tmuxRun) optTarget(a *cmdArgs, scope optScope) (*panes.Window, error) {
	t, _ := a.get('t')
	f, err := r.find(t, kindPane)
	if err != nil && strings.HasPrefix(err.Error(), "no server") {
		return nil, err
	}
	switch scope {
	case scopeWindow:
		if f.win == nil {
			what := "window"
			if a.has('p') {
				what = "pane"
			}
			return nil, errf("no such %s: %s", what, t)
		}
		return f.win, nil
	case scopeSession:
		if !f.sess {
			return nil, errf("no such session: %s", t)
		}
	}
	return f.win, nil
}

func cmdSetOption(r *tmuxRun, a *cmdArgs) error {
	name := a.args[0]
	var value string
	hasValue := len(a.args) > 1
	if hasValue {
		value = a.args[1]
	}
	scope := optionScope(a, name)
	unset := a.has('u') || a.has('U')
	w, err := r.optTarget(a, scope)
	if err != nil {
		if a.has('q') && !strings.HasPrefix(err.Error(), "no server") {
			return errQuiet
		}
		return err
	}
	if !strings.HasPrefix(name, "@") {
		return nil // a tmux option: accepted; the pane host owns terminal policy
	}
	if !unset && !hasValue {
		return errf("empty value")
	}
	if hasValue && a.has('F') {
		value = r.expand(value, &fmtCtx{r: r, win: r.view(w)})
	}
	if scope == scopeWindow {
		old, isSet, err := r.c.ShowOption(w.Index, name)
		if err != nil {
			return errf("%s", err.Error())
		}
		switch {
		case unset:
			err = r.c.UnsetOption(w.Index, name)
		case a.has('o') && isSet:
			return errf("already set: %s", name)
		case a.has('a') && isSet:
			err = r.c.SetOption(w.Index, name, old+value)
		default:
			err = r.c.SetOption(w.Index, name, value)
		}
		if err != nil {
			return errf("%s", err.Error())
		}
		r.invalidate()
		return nil
	}
	st := r.optStore()
	m := st.Session
	if scope == scopeGlobal {
		m = st.Global
	}
	old, isSet := m[name]
	switch {
	case unset:
		delete(m, name)
	case a.has('o') && isSet:
		return errf("already set: %s", name)
	case a.has('a') && isSet:
		m[name] = old + value
	default:
		m[name] = value
	}
	if err := r.saveStore(); err != nil {
		return errf("%s", err.Error())
	}
	return nil
}

func cmdShowOptions(r *tmuxRun, a *cmdArgs) error {
	name := ""
	if len(a.args) > 0 {
		name = a.args[0]
	}
	scope := optionScope(a, name)
	if name == "" {
		scope = optionScope(a, "@")
	}
	w, err := r.optTarget(a, scope)
	if err != nil {
		if a.has('q') && !strings.HasPrefix(err.Error(), "no server") {
			return nil
		}
		return err
	}
	var opts map[string]string
	switch scope {
	case scopeWindow:
		if w != nil {
			opts = w.Options
		}
	case scopeSession:
		opts = r.optStore().Session
	case scopeGlobal:
		opts = r.optStore().Global
	}
	print := func(k, v string) {
		if a.has('v') {
			r.println(v)
		} else {
			r.println(k + " " + argsEscape(v))
		}
	}
	if name == "" {
		keys := make([]string, 0, len(opts))
		for k := range opts {
			if strings.HasPrefix(k, "@") {
				keys = append(keys, k)
			}
		}
		sort.Strings(keys)
		for _, k := range keys {
			print(k, opts[k])
		}
		return nil
	}
	if !strings.HasPrefix(name, "@") {
		if v, ok := optionDefaults[name]; ok && scope == scopeGlobal {
			print(name, v)
		}
		return nil
	}
	v, ok := opts[name]
	if !ok {
		if a.has('q') {
			return nil
		}
		return errf("invalid option: %s", name)
	}
	print(name, v)
	return nil
}

// argsEscape is tmux 3.4's args_escape (show-options without -v).
func argsEscape(s string) string {
	if s == "" {
		return "''"
	}
	quote := byte(0)
	if strings.ContainsAny(s, " #';${}%") {
		quote = '"'
	} else if strings.ContainsAny(s, " \"") {
		quote = '\''
	}
	if s[0] != ' ' && len(s) == 1 && (quote != 0 || s[0] == '~') {
		return `\` + s
	}
	var b strings.Builder
	for i := 0; i < len(s); {
		c := s[i]
		if c >= 0x80 {
			_, n := decodeRune(s[i:])
			if n > 0 {
				b.WriteString(s[i : i+n])
				i += n
				continue
			}
			octal(&b, c)
			i++
			continue
		}
		switch {
		case c == '\\':
			b.WriteString(`\\`)
		case quote == '"' && c == '"':
			b.WriteString(`\"`)
		case quote == '"' && c == '$':
			b.WriteString(`\\$`)
		case c == '\n':
			b.WriteString(`\n`)
		case c == '\t':
			b.WriteString(`\t`)
		case c == '\r':
			b.WriteString(`\r`)
		case c == '\b':
			b.WriteString(`\b`)
		case c == '\a':
			b.WriteString(`\a`)
		case c == '\v':
			b.WriteString(`\v`)
		case c == '\f':
			b.WriteString(`\f`)
		case c >= 0x20 && c < 0x7f:
			b.WriteByte(c)
		default:
			octal(&b, c)
		}
		i++
	}
	e := b.String()
	switch quote {
	case '\'':
		return "'" + e + "'"
	case '"':
		if strings.HasPrefix(e, "~") {
			return `"\` + e + `"`
		}
		return `"` + e + `"`
	}
	if strings.HasPrefix(e, "~") {
		return `\` + e
	}
	return e
}

// --- windows and sessions -------------------------------------------------------

func cmdSelectWindow(r *tmuxRun, a *cmdArgs) error {
	var w *panes.Window
	var err error
	switch {
	case a.has('n') || a.has('p'):
		t, _ := a.get('t')
		if _, err := r.find(t, kindSession); err != nil {
			return err
		}
		ws, err := r.visible()
		if err != nil {
			return err
		}
		spec := "+"
		if a.has('p') {
			spec = "-"
		}
		if w, err = r.findWindow(spec, ws); err != nil {
			return errf("no next window")
		}
	case a.has('l'):
		return errf("no last window")
	default:
		if w, err = r.target(a, kindWindow); err != nil {
			return err
		}
	}
	if err := r.c.SelectWindow(w.Index); err != nil {
		return errf("%s", err.Error())
	}
	r.invalidate()
	return nil
}

func cmdKillWindow(r *tmuxRun, a *cmdArgs) error {
	w, err := r.target(a, kindWindow)
	if err != nil {
		return err
	}
	if a.has('a') {
		ws, _ := r.visible()
		for _, o := range ws {
			if o.Index != w.Index {
				_ = r.c.KillWindow(o.Index)
			}
		}
	} else if err := r.c.KillWindow(w.Index); err != nil {
		return errf("%s", err.Error())
	}
	r.invalidate()
	return nil
}

func cmdKillSession(r *tmuxRun, a *cmdArgs) error {
	t, _ := a.get('t')
	if _, err := r.find(t, kindSession); err != nil {
		return err
	}
	// A grouped view session: its clients detach (a view that is already
	// gone is fine). -a / -C: nothing to do here.
	if v := strings.TrimPrefix(t, "="); strings.HasPrefix(v, "view-") {
		if i := strings.IndexByte(v, ':'); i >= 0 {
			v = v[:i]
		}
		_, _ = r.c.DetachSession(v)
		return nil
	}
	if a.has('a') || a.has('C') {
		return nil
	}
	ws, err := r.all()
	if err != nil {
		return err
	}
	for _, w := range ws {
		_ = r.c.KillWindow(w.Index)
	}
	r.invalidate()
	return nil
}

func cmdHasSession(r *tmuxRun, a *cmdArgs) error {
	t, _ := a.get('t')
	_, err := r.find(t, kindSession)
	return err
}

func cmdResizeWindow(r *tmuxRun, a *cmdArgs) error {
	w, err := r.target(a, kindWindow)
	if err != nil {
		return err
	}
	cols, rows := w.Width, w.Height
	if x, ok := a.get('x'); ok {
		n, err := strconv.Atoi(x)
		if err != nil || n < 1 || n > 10000 {
			return errf("width invalid")
		}
		cols = n
	}
	if y, ok := a.get('y'); ok {
		n, err := strconv.Atoi(y)
		if err != nil || n < 1 || n > 10000 {
			return errf("height invalid")
		}
		rows = n
	}
	adj := 1
	if len(a.args) > 0 {
		n, err := strconv.Atoi(a.args[0])
		if err != nil || n < 1 {
			return errf("adjustment invalid")
		}
		adj = n
	}
	switch {
	case a.has('L'):
		cols -= adj
	case a.has('R'):
		cols += adj
	case a.has('U'):
		rows -= adj
	case a.has('D'):
		rows += adj
	case a.has('A') || a.has('a'):
		return nil // back to the clients' size: the pane host's policy
	}
	if cols < 1 {
		cols = 1
	}
	if rows < 1 {
		rows = 1
	}
	if err := r.c.ResizeWindow(w.Index, cols, rows); err != nil {
		return errf("%s", err.Error())
	}
	r.invalidate()
	return nil
}

// refresh-client: size authority and repaints are the pane host's (the
// frame stream sends its own repaint), so this only checks its target.
func cmdRefreshClient(r *tmuxRun, a *cmdArgs) error {
	if t, ok := a.get('t'); ok {
		cl, err := r.findClient(t)
		if err != nil {
			return err
		}
		var passive *bool
		if fl, ok := a.get('f'); ok {
			for _, f := range strings.Split(fl, ",") {
				switch f {
				case "ignore-size":
					v := true
					passive = &v
				case "!ignore-size":
					v := false
					passive = &v
				}
			}
		}
		cols, rows := 0, 0
		if cs, ok := a.get('C'); ok {
			w, h, found := strings.Cut(cs, "x")
			if !found {
				w, h, found = strings.Cut(cs, ",")
			}
			x, err1 := strconv.Atoi(w)
			y, err2 := strconv.Atoi(h)
			if !found || err1 != nil || err2 != nil || x < 1 || y < 1 || x > 10000 || y > 10000 {
				return errf("bad size argument")
			}
			cols, rows = x, y
		}
		if passive == nil && cols == 0 {
			return nil // a plain refresh: the pane host repaints on its own
		}
		if err := r.c.RefreshClient(cl.ID, passive, cols, rows); err != nil {
			return errf("%s", err.Error())
		}
		return nil
	}
	if r.getenv("TMUX_PANE") == "" && r.getenv("BROMURE_WINDOW") == "" {
		if _, err := r.all(); err != nil {
			return err
		}
		return errf("no current client")
	}
	return nil
}

// --- new windows ----------------------------------------------------------------

// shellPath is Git Bash on Windows (the daemon sets BROMURE_GIT_BASH), the
// user's shell elsewhere.
func (r *tmuxRun) shellPath() string {
	if p := r.getenv("BROMURE_GIT_BASH"); p != "" {
		return p
	}
	if runtime.GOOS == "windows" {
		for _, p := range []string{`C:\Program Files\Git\bin\bash.exe`, `C:\Program Files\Git\usr\bin\bash.exe`} {
			if _, err := os.Stat(p); err == nil {
				return p
			}
		}
		return "bash.exe"
	}
	if s := r.getenv("SHELL"); s != "" {
		return s
	}
	return "/bin/bash"
}

func (r *tmuxRun) newWindowRequest(a *cmdArgs, name string) panes.NewWindowRequest {
	sh := r.shellPath()
	req := panes.NewWindowRequest{Name: name}
	switch len(a.args) {
	case 0:
		req.Argv = []string{sh, "-l"}
		if runtime.GOOS == "windows" {
			req.Argv = []string{sh, "--login", "-i"}
		}
		if req.Name == "" {
			req.Name = strings.TrimSuffix(filepath.Base(sh), filepath.Ext(sh))
		}
	case 1:
		req.Argv = []string{sh, "-c", a.args[0]}
		if req.Name == "" {
			req.Name = firstWord(a.args[0])
		}
	default:
		req.Argv = append([]string(nil), a.args...)
		if req.Name == "" {
			req.Name = firstWord(a.args[0])
		}
	}
	cwd := homeDir()
	if c, ok := a.get('c'); ok && c != "" {
		if real, err := vpath.Default().ToReal(c); err == nil {
			cwd = real
		} else {
			cwd = c
		}
	}
	req.Cwd = cwd
	env := []string{}
	for _, kv := range os.Environ() {
		k, _, _ := strings.Cut(kv, "=")
		switch strings.ToUpper(k) {
		case "BROMURE_WINDOW", "TMUX_PANE", "TMUX":
			continue
		}
		env = append(env, kv)
	}
	req.Env = append(env, a.flags['e']...)
	return req
}

func firstWord(s string) string {
	f := strings.Fields(s)
	if len(f) == 0 {
		return "bash"
	}
	b := filepath.Base(strings.ReplaceAll(f[0], `\`, "/"))
	return strings.TrimSuffix(b, filepath.Ext(b))
}

func cmdNewWindow(r *tmuxRun, a *cmdArgs) error {
	if r.c == nil {
		return r.noServer()
	}
	if t, ok := a.get('t'); ok {
		sess, _, _ := strings.Cut(t, ":")
		if sess != "" && !strings.HasPrefix(sess, "@") && !strings.HasPrefix(sess, "%") && !isSessionName(strings.TrimPrefix(sess, "="), false) && strings.Contains(t, ":") {
			return errf("can't find session: %s", sess)
		}
	}
	name, _ := a.get('n')
	w, err := r.c.NewWindow(r.newWindowRequest(a, name))
	if err != nil {
		return errf("create window failed: %s", err.Error())
	}
	if !a.has('d') {
		_ = r.c.SelectWindow(w.Index)
	}
	r.invalidate()
	if a.has('P') {
		f, ok := a.get('F')
		if !ok {
			f = "#{session_name}:#{window_index}.#{pane_index}"
		}
		r.println(r.expand(f, &fmtCtx{r: r, win: r.view(&w)}))
	}
	return nil
}

// new-session: the one session exists whenever the pane host runs, so
// `new-session -s bromure` makes sure it has a window; another name (a
// scratch terminal) is a window carrying @bromure_scratch=<name>, reused
// by -A. Without -d the caller's terminal attaches once the command list
// has run.
func cmdNewSession(r *tmuxRun, a *cmdArgs) error {
	ws, err := r.all()
	if err != nil {
		return err
	}
	name, _ := a.get('s')
	var target *panes.Window
	if name == "" || name == panes.SessionName {
		if len(ws) > 0 {
			if !a.has('A') && name != "" {
				return errf("duplicate session: %s", name)
			}
			target = r.sessionCurrent()
		}
	} else {
		for k := range ws {
			if ws[k].Options["@bromure_scratch"] == name {
				if !a.has('A') {
					return errf("duplicate session: %s", name)
				}
				target = &ws[k]
			}
		}
	}
	if target == nil {
		wname, _ := a.get('n')
		req := r.newWindowRequest(a, wname)
		if name != "" && name != panes.SessionName {
			req.Options = map[string]string{"@bromure_scratch": name}
		}
		if x, ok := a.get('x'); ok {
			req.Cols, _ = strconv.Atoi(x)
		}
		if y, ok := a.get('y'); ok {
			req.Rows, _ = strconv.Atoi(y)
		}
		w, err := r.c.NewWindow(req)
		if err != nil {
			return errf("create session failed: %s", err.Error())
		}
		r.invalidate()
		target = &w
	}
	if a.has('P') {
		f, ok := a.get('F')
		if !ok {
			f = "#{session_name}:"
		}
		r.println(r.expand(f, &fmtCtx{r: r, win: r.view(target)}))
	}
	if !a.has('d') {
		idx := target.Index
		r.attachTo = &idx
	}
	return nil
}

func cmdAttach(r *tmuxRun, a *cmdArgs) error {
	t, _ := a.get('t')
	f, err := r.find(t, kindSession)
	if err != nil {
		return err
	}
	if strings.Contains(t, ":") || strings.HasPrefix(t, "@") || strings.HasPrefix(t, "%") {
		w, err := r.target(a, kindWindow)
		if err != nil {
			return err
		}
		f.win = w
	}
	if f.win == nil {
		return errf("no sessions")
	}
	idx := f.win.Index
	r.attachTo = &idx
	r.attachRO = a.has('r')
	return nil
}

// decodeRune is one valid multi-byte UTF-8 character's length, 0 when s
// doesn't start with one.
func decodeRune(s string) (rune, int) {
	r, n := utf8.DecodeRuneInString(s)
	if r == utf8.RuneError && n <= 1 {
		return 0, 0
	}
	return r, n
}

var _ = fmt.Sprintf
