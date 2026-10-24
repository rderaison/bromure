package panes

import (
	"strconv"
	"strings"
	"unicode/utf8"
)

// Key modifiers (xterm's parameter is 1 + the sum: S=1, M=2, C=4).
const (
	modShift = 1
	modMeta  = 2
	modCtrl  = 4
)

type keyDef struct {
	plain  string // what is sent unmodified
	cursor string // with cursor-keys (DECCKM) on, "" = same as plain
	csiNum string // xterm "\x1b[<n>;<m>~" form for modifiers ("" = letter form)
	letter byte   // xterm "\x1b[1;<m><letter>" form for modifiers
}

// keyTable is tmux 3.4's input_key_defaults for named keys.
var keyTable = map[string]keyDef{
	"enter":    {plain: "\r"},
	"escape":   {plain: "\x1b"},
	"tab":      {plain: "\t"},
	"btab":     {plain: "\x1b[Z"},
	"bspace":   {plain: "\x7f"},
	"space":    {plain: " "},
	"up":       {plain: "\x1b[A", cursor: "\x1bOA", letter: 'A'},
	"down":     {plain: "\x1b[B", cursor: "\x1bOB", letter: 'B'},
	"right":    {plain: "\x1b[C", cursor: "\x1bOC", letter: 'C'},
	"left":     {plain: "\x1b[D", cursor: "\x1bOD", letter: 'D'},
	"home":     {plain: "\x1b[1~", csiNum: "1"},
	"end":      {plain: "\x1b[4~", csiNum: "4"},
	"ic":       {plain: "\x1b[2~", csiNum: "2"},
	"dc":       {plain: "\x1b[3~", csiNum: "3"},
	"ppage":    {plain: "\x1b[5~", csiNum: "5"},
	"npage":    {plain: "\x1b[6~", csiNum: "6"},
	"f1":       {plain: "\x1bOP", letter: 'P'},
	"f2":       {plain: "\x1bOQ", letter: 'Q'},
	"f3":       {plain: "\x1bOR", letter: 'R'},
	"f4":       {plain: "\x1bOS", letter: 'S'},
	"f5":       {plain: "\x1b[15~", csiNum: "15"},
	"f6":       {plain: "\x1b[17~", csiNum: "17"},
	"f7":       {plain: "\x1b[18~", csiNum: "18"},
	"f8":       {plain: "\x1b[19~", csiNum: "19"},
	"f9":       {plain: "\x1b[20~", csiNum: "20"},
	"f10":      {plain: "\x1b[21~", csiNum: "21"},
	"f11":      {plain: "\x1b[23~", csiNum: "23"},
	"f12":      {plain: "\x1b[24~", csiNum: "24"},
	"pageup":   {plain: "\x1b[5~", csiNum: "5"},
	"pgup":     {plain: "\x1b[5~", csiNum: "5"},
	"pagedown": {plain: "\x1b[6~", csiNum: "6"},
	"pgdn":     {plain: "\x1b[6~", csiNum: "6"},
	"insert":   {plain: "\x1b[2~", csiNum: "2"},
	"delete":   {plain: "\x1b[3~", csiNum: "3"},
}

// translateKey turns one tmux key name into what a terminal would send.
// A string that isn't a key name is sent as its text, like tmux does.
// cursorKeys is the pane's DECCKM state.
func translateKey(k string, cursorKeys bool) string {
	if k == "" {
		return ""
	}
	if s, ok := lookupKey(k, cursorKeys); ok {
		return s
	}
	return k
}

func lookupKey(k string, cursorKeys bool) (string, bool) {
	mods := 0
	s := k
	// Modifier prefixes: C-, M-, S- (any order, case-insensitive) and ^x.
	for len(s) > 2 && s[1] == '-' {
		switch s[0] {
		case 'C', 'c':
			mods |= modCtrl
		case 'M', 'm':
			mods |= modMeta
		case 'S', 's':
			mods |= modShift
		default:
			goto done
		}
		s = s[2:]
	}
done:
	if len(s) == 2 && s[0] == '^' {
		mods |= modCtrl
		s = s[1:]
	}
	if len(s) > 1 && (strings.HasPrefix(s, "U+") || strings.HasPrefix(s, "u+")) {
		if v, err := strconv.ParseUint(s[2:], 16, 32); err == nil && utf8.ValidRune(rune(v)) {
			s = string(rune(v))
			if mods == 0 {
				return s, true
			}
		}
	}
	if d, ok := keyTable[strings.ToLower(s)]; ok {
		return namedKey(d, strings.ToLower(s), mods, cursorKeys), true
	}
	r, size := utf8.DecodeRuneInString(s)
	if size != len(s) || r == utf8.RuneError {
		return "", false // a word: literal text
	}
	if mods == 0 {
		return "", false
	}
	out := string(r)
	if mods&modShift != 0 && r >= 'a' && r <= 'z' {
		out = string(r - 32)
	}
	if mods&modCtrl != 0 {
		c, ok := ctrlChar(r)
		if !ok {
			return "", false
		}
		out = string(rune(c))
	}
	if mods&modMeta != 0 {
		out = "\x1b" + out
	}
	return out, true
}

func ctrlChar(r rune) (byte, bool) {
	switch {
	case r >= 'a' && r <= 'z':
		return byte(r-'a') + 1, true
	case r >= 'A' && r <= 'Z':
		return byte(r-'A') + 1, true
	case r == '@' || r == ' ' || r == '2':
		return 0, true
	case r == '[' || r == '3':
		return 0x1b, true
	case r == '\\' || r == '4':
		return 0x1c, true
	case r == ']' || r == '5':
		return 0x1d, true
	case r == '^' || r == '6' || r == '~':
		return 0x1e, true
	case r == '_' || r == '7' || r == '/' || r == '-':
		return 0x1f, true
	case r == '?' || r == '8':
		return 0x7f, true
	}
	return 0, false
}

func namedKey(d keyDef, name string, mods int, cursorKeys bool) string {
	if mods == 0 {
		if cursorKeys && d.cursor != "" {
			return d.cursor
		}
		return d.plain
	}
	m := strconv.Itoa(1 + mods)
	switch {
	case d.letter != 0:
		return "\x1b[1;" + m + string(d.letter)
	case d.csiNum != "":
		return "\x1b[" + d.csiNum + ";" + m + "~"
	}
	// Single-byte keys: Ctrl/Meta the usual way.
	out := d.plain
	switch name {
	case "space":
		if mods&modCtrl != 0 {
			out = "\x00"
		}
	case "tab":
		if mods&modShift != 0 {
			out = "\x1b[Z"
		}
	case "bspace":
		if mods&modCtrl != 0 {
			out = "\x08"
		}
	}
	if mods&modMeta != 0 {
		out = "\x1b" + out
	}
	return out
}
