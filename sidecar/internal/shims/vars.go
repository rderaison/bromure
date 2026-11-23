package shims

import (
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/panes"
	"github.com/rderaison/bromure/sidecar/internal/vpath"
)

// winView is one window as formats see it; the screen (cursor, alternate
// screen) is fetched only when a format asks for it.
type winView struct {
	w         panes.Window
	r         *tmuxRun
	screen    *panes.Screen
	screenErr bool
}

func (v *winView) scr() *panes.Screen {
	if v.screen == nil && !v.screenErr {
		s, err := v.r.c.Screen(v.w.Index)
		if err != nil {
			v.screenErr = true
			return nil
		}
		v.screen = &s
	}
	return v.screen
}

type clientView = panes.ClientInfo

func (r *tmuxRun) view(w *panes.Window) *winView {
	if w == nil {
		return nil
	}
	return &winView{w: *w, r: r}
}

func itoa(n int) string { return strconv.Itoa(n) }

func flag01(b bool) string {
	if b {
		return "1"
	}
	return "0"
}

// varFunc returns a variable's value; ok=false is tmux's "not found"
// (NULL), which matters to #{?…}.
type varFunc func(r *tmuxRun, ctx *fmtCtx) (string, bool)

func winVar(f func(v *winView) string) varFunc {
	return func(r *tmuxRun, ctx *fmtCtx) (string, bool) {
		if ctx.win == nil {
			return "", false
		}
		return f(ctx.win), true
	}
}

func scrVar(f func(s *panes.Screen, v *winView) string) varFunc {
	return func(r *tmuxRun, ctx *fmtCtx) (string, bool) {
		if ctx.win == nil {
			return "", false
		}
		s := ctx.win.scr()
		if s == nil {
			return "", false
		}
		return f(s, ctx.win), true
	}
}

func cliVar(f func(c *clientView) string) varFunc {
	return func(r *tmuxRun, ctx *fmtCtx) (string, bool) {
		if ctx.client == nil {
			return "", false
		}
		return f(ctx.client), true
	}
}

func sessVar(f func(r *tmuxRun) string) varFunc {
	return func(r *tmuxRun, ctx *fmtCtx) (string, bool) {
		if ctx.noSess {
			return "", false
		}
		return f(r), true
	}
}

func constVar(s string) varFunc {
	return func(*tmuxRun, *fmtCtx) (string, bool) { return s, true }
}

func layout(v *winView) string {
	body := itoa(v.w.Width) + "x" + itoa(v.w.Height) + ",0,0," + strings.TrimPrefix(v.w.PaneID, "%")
	csum := 0
	for i := 0; i < len(body); i++ {
		csum = (csum >> 1) + ((csum & 1) << 15)
		csum += int(body[i])
		csum &= 0xffff
	}
	return strconv.FormatInt(int64(csum), 16) + "," + body
}

func winFlags(v *winView) string {
	if v.w.Active {
		return "*"
	}
	return ""
}

func (r *tmuxRun) paneTitle(v *winView) string {
	if v.w.Title != "" {
		return v.w.Title
	}
	return r.hostname() // tmux's default pane title
}

func epoch(t time.Time) string {
	if t.IsZero() {
		return "0"
	}
	return strconv.FormatInt(t.Unix(), 10)
}

// variables is every #{name} the shim knows. Client formats must only use
// these (the contract test checks).
var variables map[string]varFunc

func init() {
	variables = map[string]varFunc{
		// server
		"version":     constVar(tmuxVersion),
		"pid":         func(r *tmuxRun, _ *fmtCtx) (string, bool) { return itoa(os.Getpid()), true },
		"host":        func(r *tmuxRun, _ *fmtCtx) (string, bool) { return r.hostname(), true },
		"host_short":  func(r *tmuxRun, _ *fmtCtx) (string, bool) { h, _, _ := strings.Cut(r.hostname(), "."); return h, true },
		"socket_path": func(r *tmuxRun, _ *fmtCtx) (string, bool) { return r.socketPath(), true },
		"start_time":  func(r *tmuxRun, _ *fmtCtx) (string, bool) { return r.sessionCreated(), true },
		"uid":         constVar("1000"),
		"user":        func(r *tmuxRun, _ *fmtCtx) (string, bool) { return userName(), true },

		// session
		"session_name":          sessVar(func(*tmuxRun) string { return panes.SessionName }),
		"session_id":            sessVar(func(*tmuxRun) string { return "$0" }),
		"session_windows":       sessVar(func(r *tmuxRun) string { ws, _ := r.visible(); return itoa(len(ws)) }),
		"session_attached":      sessVar(func(r *tmuxRun) string { cs, _ := r.clients(); return itoa(len(cs)) }),
		"session_many_attached": sessVar(func(r *tmuxRun) string { cs, _ := r.clients(); return flag01(len(cs) > 1) }),
		"session_created":       sessVar(func(r *tmuxRun) string { return r.sessionCreated() }),
		"session_activity":      sessVar(func(r *tmuxRun) string { return r.sessionCreated() }),
		"session_grouped":       sessVar(func(*tmuxRun) string { return "0" }),
		"session_group":         sessVar(func(*tmuxRun) string { return "" }),
		"session_format":        sessVar(func(*tmuxRun) string { return "1" }),
		"session_path":          sessVar(func(*tmuxRun) string { return vpath.Default().MustVirtual(homeDir()) }),

		// window
		"window_index":          winVar(func(v *winView) string { return itoa(v.w.Index) }),
		"window_id":             winVar(func(v *winView) string { return v.w.ID }),
		"window_name":           winVar(func(v *winView) string { return v.w.Name }),
		"window_active":         winVar(func(v *winView) string { return flag01(v.w.Active) }),
		"window_flags":          winVar(winFlags),
		"window_raw_flags":      winVar(winFlags),
		"window_panes":          winVar(func(*winView) string { return "1" }),
		"window_width":          winVar(func(v *winView) string { return itoa(v.w.Width) }),
		"window_height":         winVar(func(v *winView) string { return itoa(v.w.Height) }),
		"window_layout":         winVar(layout),
		"window_visible_layout": winVar(layout),
		"window_zoomed_flag":    winVar(func(*winView) string { return "0" }),
		"window_last_flag":      winVar(func(*winView) string { return "0" }),
		"window_bell_flag":      winVar(func(*winView) string { return "0" }),
		"window_activity_flag":  winVar(func(*winView) string { return "0" }),
		"window_silence_flag":   winVar(func(*winView) string { return "0" }),
		"window_linked":         winVar(func(*winView) string { return "0" }),
		"window_marked_flag":    winVar(func(*winView) string { return "0" }),
		"window_format":         winVar(func(*winView) string { return "1" }),
		"window_activity":       winVar(func(v *winView) string { return epoch(v.w.StartedAt) }),
		"window_start_flag": func(r *tmuxRun, ctx *fmtCtx) (string, bool) {
			if ctx.win == nil {
				return "", false
			}
			ws, _ := r.visible()
			return flag01(len(ws) > 0 && ws[0].Index == ctx.win.w.Index), true
		},
		"window_end_flag": func(r *tmuxRun, ctx *fmtCtx) (string, bool) {
			if ctx.win == nil {
				return "", false
			}
			ws, _ := r.visible()
			return flag01(len(ws) > 0 && ws[len(ws)-1].Index == ctx.win.w.Index), true
		},
		"active_window_index": func(r *tmuxRun, ctx *fmtCtx) (string, bool) {
			if ctx.noSess {
				return "", false
			}
			if w := r.current(); w != nil {
				return itoa(w.Index), true
			}
			return "", false
		},

		// pane (one per window)
		"pane_id":              winVar(func(v *winView) string { return v.w.PaneID }),
		"pane_index":           winVar(func(*winView) string { return "0" }),
		"pane_active":          winVar(func(*winView) string { return "1" }),
		"pane_last":            winVar(func(*winView) string { return "0" }),
		"pane_tty":             winVar(func(v *winView) string { return v.w.TTY }),
		"pane_pid":             winVar(func(v *winView) string { return itoa(v.w.PID) }),
		"pane_current_path":    winVar(func(v *winView) string { return vpath.Default().MustVirtual(v.w.Cwd) }),
		"pane_path":            winVar(func(v *winView) string { return "" }),
		"pane_current_command": winVar(func(v *winView) string { return v.w.Command }),
		"pane_start_command":   winVar(func(v *winView) string { return "" }),
		"pane_start_path":      winVar(func(v *winView) string { return "" }),
		"pane_title": func(r *tmuxRun, ctx *fmtCtx) (string, bool) {
			if ctx.win == nil {
				return "", false
			}
			return r.paneTitle(ctx.win), true
		},
		"pane_width":          winVar(func(v *winView) string { return itoa(v.w.Width) }),
		"pane_height":         winVar(func(v *winView) string { return itoa(v.w.Height) }),
		"pane_left":           winVar(func(*winView) string { return "0" }),
		"pane_top":            winVar(func(*winView) string { return "0" }),
		"pane_right":          winVar(func(v *winView) string { return itoa(v.w.Width - 1) }),
		"pane_bottom":         winVar(func(v *winView) string { return itoa(v.w.Height - 1) }),
		"pane_at_left":        winVar(func(*winView) string { return "1" }),
		"pane_at_right":       winVar(func(*winView) string { return "1" }),
		"pane_at_top":         winVar(func(*winView) string { return "1" }),
		"pane_at_bottom":      winVar(func(*winView) string { return "1" }),
		"pane_dead":           winVar(func(v *winView) string { return flag01(!v.w.Alive) }),
		"pane_dead_status":    winVar(deadStatus),
		"pane_dead_signal":    winVar(func(*winView) string { return "" }),
		"pane_dead_time":      winVar(func(*winView) string { return "" }),
		"pane_in_mode":        winVar(func(*winView) string { return "0" }),
		"pane_mode":           winVar(func(*winView) string { return "" }),
		"pane_marked":         winVar(func(*winView) string { return "0" }),
		"pane_marked_set":     winVar(func(*winView) string { return "0" }),
		"pane_input_off":      winVar(func(*winView) string { return "0" }),
		"pane_pipe":           winVar(func(*winView) string { return "0" }),
		"pane_synchronized":   winVar(func(*winView) string { return "0" }),
		"pane_format":         winVar(func(*winView) string { return "1" }),
		"pane_unseen_changes": winVar(func(*winView) string { return "0" }),
		"history_size":        winVar(func(*winView) string { return "0" }),
		"history_limit":       winVar(func(*winView) string { return "10000" }),
		"history_bytes":       winVar(func(*winView) string { return "0" }),
		"scroll_position":     winVar(func(*winView) string { return "" }),

		// screen state
		"alternate_on":        scrVar(func(s *panes.Screen, _ *winView) string { return flag01(s.AltScreen) }),
		"cursor_flag":         scrVar(func(s *panes.Screen, _ *winView) string { return flag01(s.CursorVisible) }),
		"cursor_x":            scrVar(func(s *panes.Screen, _ *winView) string { return itoa(s.CursorX) }),
		"cursor_y":            scrVar(func(s *panes.Screen, _ *winView) string { return itoa(s.CursorY) }),
		"scroll_region_upper": scrVar(func(*panes.Screen, *winView) string { return "0" }),
		"scroll_region_lower": scrVar(func(s *panes.Screen, _ *winView) string { return itoa(s.Height - 1) }),
		"insert_flag":         scrVar(func(*panes.Screen, *winView) string { return "0" }),
		"keypad_flag":         scrVar(func(*panes.Screen, *winView) string { return "0" }),
		"keypad_cursor_flag":  scrVar(func(*panes.Screen, *winView) string { return "0" }),
		"origin_flag":         scrVar(func(*panes.Screen, *winView) string { return "0" }),
		"wrap_flag":           scrVar(func(*panes.Screen, *winView) string { return "1" }),
		"mouse_any_flag":      scrVar(func(*panes.Screen, *winView) string { return "0" }),
		"mouse_standard_flag": scrVar(func(*panes.Screen, *winView) string { return "0" }),
		"mouse_sgr_flag":      scrVar(func(*panes.Screen, *winView) string { return "0" }),

		// client
		"client_name":   cliVar(clientTTY),
		"client_tty":    cliVar(clientTTY),
		"client_width":  cliVar(func(c *clientView) string { return itoa(c.Cols) }),
		"client_height": cliVar(func(c *clientView) string { return itoa(c.Rows) }),
		"client_flags":  cliVar(func(c *clientView) string { return c.Flags }),
		"client_session": cliVar(func(c *clientView) string {
			if c.Session != "" {
				return c.Session
			}
			return panes.SessionName
		}),
		"client_last_session": cliVar(func(*clientView) string { return "" }),
		"client_termname":     cliVar(func(*clientView) string { return "xterm-256color" }),
		"client_termtype":     cliVar(func(*clientView) string { return "" }),
		"client_termfeatures": cliVar(func(*clientView) string { return "" }),
		"client_activity":     cliVar(func(c *clientView) string { return epoch(c.Activity) }),
		"client_created":      cliVar(func(c *clientView) string { return epoch(c.Activity) }),
		"client_pid":          cliVar(func(*clientView) string { return "0" }),
		"client_uid":          cliVar(func(*clientView) string { return "1000" }),
		"client_user":         cliVar(func(*clientView) string { return userName() }),
		"client_utf8":         cliVar(func(*clientView) string { return "1" }),
		"client_readonly":     cliVar(func(c *clientView) string { return flag01(strings.Contains(c.Flags, "read-only")) }),
		"client_control_mode": cliVar(func(*clientView) string { return "0" }),
		"client_prefix":       cliVar(func(*clientView) string { return "0" }),
		"client_key_table":    cliVar(func(*clientView) string { return "root" }),
		"client_written":      cliVar(func(*clientView) string { return "0" }),
		"client_discarded":    cliVar(func(*clientView) string { return "0" }),
		"client_cell_width":   cliVar(func(*clientView) string { return "0" }),
		"client_cell_height":  cliVar(func(*clientView) string { return "0" }),
	}
}

// clientTTY is client_tty / client_name: the client's fake tty, which
// refresh-client -t takes back.
func clientTTY(c *clientView) string {
	if c.TTY != "" {
		return c.TTY
	}
	return c.ID
}

func deadStatus(v *winView) string {
	if v.w.Alive || v.w.ExitCode == nil {
		return ""
	}
	return itoa(*v.w.ExitCode)
}

// knownVariable says whether name is a variable or option the shim
// expands (for the contract test).
func knownVariable(name string) bool {
	if strings.HasPrefix(name, "@") {
		return true
	}
	if _, ok := variables[name]; ok {
		return true
	}
	_, ok := optionDefaults[name]
	return ok
}

// variableNames lists the known variables, sorted (display-message -a).
func variableNames() []string {
	names := make([]string, 0, len(variables))
	for k := range variables {
		names = append(names, k)
	}
	sort.Strings(names)
	return names
}

// lookup is format_find: a variable, then a user option (@x: window, then
// session, then global), then a tmux option's default.
func (r *tmuxRun) lookup(name string, ctx *fmtCtx) (string, bool) {
	if r.onLookup != nil {
		r.onLookup(name)
	}
	if f, ok := variables[name]; ok {
		return f(r, ctx)
	}
	if strings.HasPrefix(name, "@") {
		if ctx.win != nil {
			if v, ok := ctx.win.w.Options[name]; ok {
				return v, true
			}
		}
		st := r.optStore()
		if !ctx.noSess {
			if v, ok := st.Session[name]; ok {
				return v, true
			}
		}
		if v, ok := st.Global[name]; ok {
			return v, true
		}
		return "", false
	}
	if v, ok := optionDefaults[name]; ok {
		return v, true
	}
	return "", false
}

// optionDefaults are the tmux options the client sets or reads, with the
// values a Bromure guest's tmux.conf gives them. Setting one is accepted
// and does nothing here (the pane host has its own policy).
var optionDefaults = map[string]string{
	"mouse":              "off",
	"status":             "off",
	"window-size":        "latest",
	"history-limit":      "10000",
	"escape-time":        "10",
	"base-index":         "0",
	"renumber-windows":   "off",
	"set-clipboard":      "on",
	"default-terminal":   "tmux-256color",
	"allow-passthrough":  "off",
	"aggressive-resize":  "off",
	"automatic-rename":   "off",
	"allow-rename":       "off",
	"remain-on-exit":     "off",
	"focus-events":       "off",
	"extended-keys":      "off",
	"set-titles":         "off",
	"monitor-activity":   "off",
	"pane-base-index":    "0",
	"default-shell":      "/bin/bash",
	"default-command":    "",
	"prefix":             "C-b",
	"status-position":    "bottom",
	"visual-activity":    "off",
	"destroy-unattached": "off",
	"exit-empty":         "on",
	"exit-unattached":    "off",
	"mode-keys":          "emacs",
	"status-keys":        "emacs",
	"terminal-features":  "",
	"terminal-overrides": "",
	"update-environment": "",
	"word-separators":    "!\"#$%&'()*+,-./:;<=>?@[\\]^`{|}~",
	"wrap-search":        "on",
	"xterm-keys":         "on",
	"buffer-limit":       "50",
	"display-time":       "750",
	"repeat-time":        "500",
	"synchronize-panes":  "off",
	"alternate-screen":   "on",
	"scroll-on-clear":    "on",
	"main-pane-height":   "24",
	"main-pane-width":    "80",
}
