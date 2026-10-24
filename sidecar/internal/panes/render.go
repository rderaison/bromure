package panes

import (
	"bytes"
	"fmt"
	"runtime"
	"sort"
	"strconv"
	"strings"
)

// capture renders lines like tmux 3.4's capture-pane (cmd-capture-pane.c):
// line numbers are relative to the first visible line (negative = history),
// out-of-range numbers clamp, a reversed range is swapped. Every line ends
// in "\n" (blank ones included, as tmux prints them) except, with Join, a
// wrapped line, which runs into the next. Without Join each line is the
// full width with trailing spaces trimmed; with Join it is what was written
// (trailing spaces kept, never-written cells left out).
func (t *term) capture(o CaptureOptions) string {
	h := t.hist()
	hs := len(h)
	last := hs + t.rows - 1
	top := hs
	switch {
	case o.StartHistory:
		top = 0
	case o.Start != nil:
		n := *o.Start
		if n < 0 && -n > hs {
			top = 0
		} else {
			top = hs + n
		}
		if top > last {
			top = last
		}
	}
	bottom := last
	switch {
	case o.EndVisible:
	case o.End != nil:
		n := *o.End
		if n < 0 && -n > hs {
			bottom = 0
		} else {
			bottom = hs + n
		}
		if bottom > last {
			bottom = last
		}
	}
	if bottom < top {
		top, bottom = bottom, top
	}
	var b strings.Builder
	var lastA attr
	for i := top; i <= bottom; i++ {
		var l line
		if i < hs {
			l = h[i]
		} else {
			l = t.lines[i-hs]
		}
		b.WriteString(t.lineString(l, o.Join, o.Escapes, &lastA))
		if !o.Join || !l.wrapped {
			b.WriteByte('\n')
		}
	}
	return b.String()
}

// usedCells is how far a line was written (tmux's cellused).
func usedCells(cells []cell) int {
	for n := len(cells); n > 0; n-- {
		c := cells[n-1]
		if c.r != 0 || c.w == 0 {
			return n
		}
	}
	return 0
}

func (t *term) lineString(l line, join, esc bool, last *attr) string {
	end := len(l.cells)
	if join {
		end = usedCells(l.cells)
	}
	var b strings.Builder
	for x := 0; x < end; x++ {
		c := l.cells[x]
		if c.w == 0 {
			continue
		}
		if esc && c.a != *last {
			b.WriteString(sgrTransition(*last, c.a))
			*last = c.a
		}
		b.WriteString(t.cellText(c))
	}
	s := b.String()
	if !join {
		s = strings.TrimRight(s, " ")
	}
	return s
}

// screenText is the visible screen, lines trimmed, "\n"-joined.
func (t *term) screenText() string {
	parts := make([]string, len(t.lines))
	var a attr
	for i, l := range t.lines {
		parts[i] = t.lineString(l, false, false, &a)
	}
	return strings.Join(parts, "\n")
}

var attrCodes = []struct {
	m    uint16
	code string
}{
	{aBold, "1"}, {aDim, "2"}, {aItalic, "3"}, {aUnderline, "4"}, {aBlink, "5"},
	{aReverse, "7"}, {aHidden, "8"}, {aStrike, "9"}, {aDoubleUnderline, "4:2"}, {aOverline, "53"},
}

func colorCode(c uint32, bg bool) string {
	base := 30
	if bg {
		base = 40
	}
	switch {
	case c == 0:
		return strconv.Itoa(base + 9)
	case c&colRGB != 0:
		return fmt.Sprintf("%d;2;%d;%d;%d", base+8, (c>>16)&0xff, (c>>8)&0xff, c&0xff)
	case c <= 8:
		return strconv.Itoa(base + int(c) - 1)
	case c <= 16:
		return strconv.Itoa(base + 60 + int(c) - 9)
	default:
		return fmt.Sprintf("%d;5;%d", base+8, c-1)
	}
}

// sgrTransition is the SGR that takes a terminal from one cell style to
// another, the way tmux's grid_string_cells_code writes it: a removed
// attribute starts with 0, then new attributes, then changed colours.
func sgrTransition(from, to attr) string {
	var codes []string
	lastFl, fg, bg := from.fl, from.fg, from.bg
	if from.fl&^to.fl != 0 {
		codes = append(codes, "0")
		lastFl, fg, bg = 0, 0, 0
	}
	for _, ac := range attrCodes {
		if to.fl&ac.m != 0 && lastFl&ac.m == 0 {
			codes = append(codes, ac.code)
		}
	}
	if to.fg != fg {
		codes = append(codes, colorCode(to.fg, false))
	}
	if to.bg != bg {
		codes = append(codes, colorCode(to.bg, true))
	}
	if len(codes) == 0 {
		return ""
	}
	return "\x1b[" + strings.Join(codes, ";") + "m"
}

func (t *term) paintLines(b *bytes.Buffer, lines []line, last *attr) {
	for y, l := range lines {
		end := len(l.cells)
		for end > 0 {
			c := l.cells[end-1]
			if c.r != 0 || c.w != 1 || c.a != (attr{}) {
				break
			}
			end--
		}
		if end == 0 {
			continue
		}
		fmt.Fprintf(b, "\x1b[%d;1H", y+1)
		for x := 0; x < end; x++ {
			c := l.cells[x]
			if c.w == 0 {
				continue
			}
			if c.a != *last {
				b.WriteString(sgrTransition(*last, c.a))
				*last = c.a
			}
			b.WriteString(t.cellText(c))
		}
	}
}

// repaint brings a fresh client terminal to the model's state: the main
// screen (under the alternate one, when that is up, so leaving it shows
// the right thing), the visible screen, modes, scroll region, cursor, pen.
func (t *term) repaint() []byte {
	var b bytes.Buffer
	b.WriteString("\x1b[0m\x1b[?25l\x1b[?6l\x1b[?7h\x1b[4l\x1b[r\x1b(B\x1b)B\x0f\x1b[H\x1b[2J")
	var last attr
	if t.alt && t.mainLines != nil {
		t.paintLines(&b, t.mainLines, &last)
		b.WriteString("\x1b[0m")
		last = attr{}
		ac := t.altCursor
		fmt.Fprintf(&b, "\x1b[%d;%dH", ac.y+1, ac.x+1)
		b.WriteString("\x1b[?1049h\x1b[H\x1b[2J")
	}
	t.paintLines(&b, t.lines, &last)
	b.WriteString("\x1b[0m")
	if !t.autowrap {
		b.WriteString("\x1b[?7l")
	}
	if t.insert {
		b.WriteString("\x1b[4h")
	}
	if t.cursorKeys {
		b.WriteString("\x1b[?1h")
	}
	if t.keypad {
		b.WriteString("\x1b=")
	}
	if t.bracketed {
		b.WriteString("\x1b[?2004h")
	}
	if t.focus {
		b.WriteString("\x1b[?1004h")
	}
	var ms []int
	for m := range t.mouse {
		ms = append(ms, m)
	}
	sort.Ints(ms)
	for _, m := range ms {
		fmt.Fprintf(&b, "\x1b[?%dh", m)
	}
	if t.top != 0 || t.bot != t.rows-1 {
		fmt.Fprintf(&b, "\x1b[%d;%dr", t.top+1, t.bot+1)
	}
	if t.origin {
		b.WriteString("\x1b[?6h")
	}
	if t.charsets[0] != 'B' {
		b.WriteString("\x1b(" + string(t.charsets[0]))
	}
	if t.charsets[1] != 'B' {
		b.WriteString("\x1b)" + string(t.charsets[1]))
	}
	if t.gl == 1 {
		b.WriteByte(0x0e)
	}
	x, y := t.cursorReport()
	fmt.Fprintf(&b, "\x1b[%d;%dH", y, x)
	b.WriteString(sgrTransition(attr{}, t.pen))
	if t.cursorVisible {
		b.WriteString("\x1b[?25h")
	}
	return b.Bytes()
}

// nativeCwd maps an OSC 7 path to a real one: on Windows "/c/Users/x"
// (MSYS) and "/C:/Users/x" (file URL) are "C:\Users\x".
func nativeCwd(p string) string {
	if runtime.GOOS != "windows" {
		return p
	}
	switch {
	case len(p) >= 3 && p[0] == '/' && isLetter(p[1]) && p[2] == ':':
		p = p[1:]
	case len(p) >= 2 && p[0] == '/' && isLetter(p[1]) && (len(p) == 2 || p[2] == '/'):
		p = strings.ToUpper(p[1:2]) + ":" + p[2:]
		if len(p) == 2 {
			p += "/"
		}
	}
	return strings.ReplaceAll(p, "/", `\`)
}

func isLetter(b byte) bool { return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') }
