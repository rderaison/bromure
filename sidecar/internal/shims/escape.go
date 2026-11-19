package shims

import (
	"os"
	"runtime"
	"strings"
	"unicode/utf8"
)

// visEscape is what tmux 3.4 does to every line a command prints through
// cmdq_print (list-* -F, display-message -p, show-options, new-window -P):
// utf8_stravisx(VIS_OCTAL|VIS_CSTYLE|VIS_NOSLASH). Printable ASCII, space,
// TAB and LF pass; \a \b \v \f \r get their C names; every other control
// byte, DEL and each byte of invalid UTF-8 becomes \ooo; a backslash is not
// doubled; valid UTF-8 passes. (Checked against tmux 3.4: a tab in an
// option prints raw, \037 prints as the four characters `\037`.)
func visEscape(s string) string {
	if isPlain(s) {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); {
		c := s[i]
		if c >= 0x80 {
			r, n := utf8.DecodeRuneInString(s[i:])
			if r != utf8.RuneError || n > 1 {
				b.WriteString(s[i : i+n])
				i += n
				continue
			}
			octal(&b, c)
			i++
			continue
		}
		switch {
		case c == '\t' || c == '\n' || (c >= 0x20 && c < 0x7f):
			b.WriteByte(c)
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
		case c == 0:
			if i+1 < len(s) && s[i+1] >= '0' && s[i+1] <= '7' {
				b.WriteString(`\000`)
			} else {
				b.WriteString(`\0`)
			}
		default:
			octal(&b, c)
		}
		i++
	}
	return b.String()
}

func octal(b *strings.Builder, c byte) {
	b.WriteByte('\\')
	b.WriteByte('0' + (c>>6)&7)
	b.WriteByte('0' + (c>>3)&7)
	b.WriteByte('0' + c&7)
}

func isPlain(s string) bool {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c != '\t' && c != '\n' && (c < 0x20 || c >= 0x7f) {
			return false
		}
	}
	return true
}

// sanitizeASCII is tmux's utf8_sanitize, applied to printed lines when the
// client isn't UTF-8: anything outside 0x20..0x7e becomes '_' (a wide
// character two of them). tmux applies it after visEscape, so a TAB there
// becomes '_' too.
func sanitizeASCII(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch {
		case r > 0x1f && r < 0x7f:
			b.WriteRune(r)
		case r >= 0x80 && isWide(r):
			b.WriteString("__")
		default:
			b.WriteByte('_')
		}
	}
	return b.String()
}

func isWide(r rune) bool {
	return (r >= 0x1100 && r <= 0x115f) || (r >= 0x2e80 && r <= 0xa4cf) ||
		(r >= 0xac00 && r <= 0xd7a3) || (r >= 0xf900 && r <= 0xfaff) ||
		(r >= 0xfe30 && r <= 0xfe4f) || (r >= 0xff00 && r <= 0xff60) ||
		(r >= 0xffe0 && r <= 0xffe6) || (r >= 0x1f300 && r <= 0x1faff) ||
		(r >= 0x20000 && r <= 0x3fffd)
}

// clientIsUTF8 is tmux's test: -u, or $TMUX set (a client inside tmux), or
// the first non-empty of LC_ALL, LC_CTYPE, LANG naming UTF-8. Deviation on
// Windows: no locale at all counts as UTF-8 (Windows has no C locale in
// that sense, and a stray `_` in a pane title helps nobody).
func clientIsUTF8(flagU bool, getenv func(string) string) bool {
	if flagU || getenv("TMUX") != "" {
		return true
	}
	s := getenv("LC_ALL")
	if s == "" {
		s = getenv("LC_CTYPE")
	}
	if s == "" {
		s = getenv("LANG")
	}
	if s == "" {
		return runtime.GOOS == "windows"
	}
	u := strings.ToUpper(s)
	return strings.Contains(u, "UTF-8") || strings.Contains(u, "UTF8")
}

var osGetenv = os.Getenv
