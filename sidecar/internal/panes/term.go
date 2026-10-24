package panes

import (
	"bytes"
	"fmt"
	"strconv"
	"strings"
	"unicode/utf8"
)

// term is the VT screen model behind a window: what tmux's screen/grid is
// to a pane. It is fed the program's output and keeps the visible screen,
// the main screen's history (shared, like tmux, while the alternate screen
// is up), the cursor and the modes a client needs to be repainted into the
// same state. Not safe for concurrent use: the window's lock guards it.
//
// write also filters the stream it is fed: what attached clients get is the
// same bytes minus terminal queries (answered here, the way tmux answers
// for its panes) and ConPTY's win32-input-mode request.
type term struct {
	cols, rows int
	lines      []line
	history    []line
	histMax    int

	alt       bool
	mainLines []line // the main screen while the alternate one is up
	altCursor savedCursor

	cx, cy   int
	wrapNext bool
	pen      attr
	saved    savedCursor
	top, bot int // scroll region, inclusive

	insert, autowrap, origin, lnm     bool
	cursorKeys, keypad, cursorVisible bool
	bracketed, focus                  bool
	mouse                             map[int]bool // 9, 1000, 1002, 1003, 1005, 1006, 1015, 1016
	charsets                          [2]byte
	gl                                int
	tabs                              []bool
	lastChar                          rune

	title, cwd string

	combs   []string
	combIdx map[string]int

	// parser
	state  int
	seq    []byte // raw bytes of the sequence being parsed
	csi    []byte // CSI body (params, intermediates)
	oscBuf []byte
	strTyp byte // 'P' DCS, 'X' SOS, '^' PM, '_' APC
	inter  []byte
	ubuf   [4]byte
	ulen   int
	uneed  int

	out     []byte // filtered output for clients
	replies []byte // answers for the program
}

type attr struct {
	fl     uint16
	fg, bg uint32 // 0 default; 1..256 palette (index+1); colRGB|0xRRGGBB
}

const colRGB = 1 << 24

const (
	aBold uint16 = 1 << iota
	aDim
	aItalic
	aUnderline
	aBlink
	aReverse
	aHidden
	aStrike
	aDoubleUnderline
	aOverline
)

type cell struct {
	r rune  // 0 = empty; >= combBase indexes term.combs
	w uint8 // 1, 2 = wide lead, 0 = the wide char's second half
	a attr
}

const combBase = 0x110000

type line struct {
	cells   []cell
	wrapped bool
}

type savedCursor struct {
	x, y     int
	pen      attr
	origin   bool
	charsets [2]byte
	gl       int
	wrapNext bool
	set      bool
}

const (
	stGround = iota
	stEsc
	stCSI
	stOSC
	stOSCEsc
	stStr
	stStrEsc
)

const maxSeq = 1 << 20

func newTerm(cols, rows, histMax int) *term {
	if cols < 1 {
		cols = 1
	}
	if rows < 1 {
		rows = 1
	}
	t := &term{cols: cols, rows: rows, histMax: histMax, combIdx: map[string]int{}}
	t.reset()
	return t
}

func (t *term) reset() {
	t.lines = make([]line, t.rows)
	for i := range t.lines {
		t.lines[i] = t.blankLine(attr{})
	}
	t.alt, t.mainLines = false, nil
	t.cx, t.cy, t.wrapNext = 0, 0, false
	t.pen = attr{}
	t.saved, t.altCursor = savedCursor{}, savedCursor{}
	t.top, t.bot = 0, t.rows-1
	t.insert, t.origin, t.lnm = false, false, false
	t.autowrap, t.cursorVisible = true, true
	t.cursorKeys, t.keypad, t.bracketed, t.focus = false, false, false, false
	t.mouse = map[int]bool{}
	t.charsets = [2]byte{'B', 'B'}
	t.gl = 0
	t.resetTabs()
}

func (t *term) resetTabs() {
	t.tabs = make([]bool, t.cols)
	for i := 8; i < t.cols; i += 8 {
		t.tabs[i] = true
	}
}

func (t *term) blankLine(a attr) line {
	l := line{cells: make([]cell, t.cols)}
	bg := attr{bg: a.bg}
	for i := range l.cells {
		l.cells[i] = cell{w: 1, a: bg}
	}
	return l
}

func blankCell(a attr) cell { return cell{w: 1, a: attr{bg: a.bg}} }

// takeOutput returns (and forgets) the filtered stream for clients.
func (t *term) takeOutput() []byte {
	o := t.out
	t.out = nil
	return o
}

// takeReplies returns (and forgets) the answers owed to the program.
func (t *term) takeReplies() []byte {
	r := t.replies
	t.replies = nil
	return r
}

func (t *term) reply(format string, a ...any) {
	t.replies = append(t.replies, fmt.Sprintf(format, a...)...)
}

// write feeds program output.
func (t *term) write(p []byte) {
	for _, b := range p {
		t.feed(b)
	}
}

func (t *term) feed(b byte) {
	switch t.state {
	case stGround:
		t.ground(b)
		return
	}
	// Inside a sequence: CAN/SUB abort it, ESC restarts (except as the
	// first half of a string terminator).
	t.seq = append(t.seq, b)
	if len(t.seq) > maxSeq {
		t.flushSeq(true)
		t.state = stGround
		return
	}
	switch t.state {
	case stEsc:
		t.escByte(b)
	case stCSI:
		t.csiByte(b)
	case stOSC:
		switch b {
		case 0x07:
			t.oscDone()
		case 0x1b:
			t.state = stOSCEsc
		case 0x18, 0x1a:
			t.flushSeq(true)
			t.state = stGround
		default:
			t.oscBuf = append(t.oscBuf, b)
		}
	case stOSCEsc:
		if b == '\\' {
			t.oscDone()
			return
		}
		// Not ST: the OSC is over; this ESC starts a new sequence.
		t.seq = t.seq[:len(t.seq)-2]
		t.oscDone()
		t.state = stEsc
		t.seq = append(t.seq[:0], 0x1b, b)
		t.inter = t.inter[:0]
		t.escByte(b)
	case stStr:
		switch b {
		case 0x1b:
			t.state = stStrEsc
		case 0x07:
			if t.strTyp != 'P' {
				t.strDone()
			} else {
				t.oscBuf = append(t.oscBuf, b)
			}
		case 0x18, 0x1a:
			t.flushSeq(true)
			t.state = stGround
		default:
			t.oscBuf = append(t.oscBuf, b)
		}
	case stStrEsc:
		if b == '\\' {
			t.strDone()
			return
		}
		t.seq = t.seq[:len(t.seq)-2]
		t.strDone()
		t.state = stEsc
		t.seq = append(t.seq[:0], 0x1b, b)
		t.inter = t.inter[:0]
		t.escByte(b)
	}
}

// flushSeq ends the current sequence, forwarding its bytes when keep.
func (t *term) flushSeq(keep bool) {
	if keep {
		t.out = append(t.out, t.seq...)
	}
	t.seq = t.seq[:0]
}

func (t *term) ground(b byte) {
	if t.uneed > 0 {
		if b&0xc0 == 0x80 {
			t.ubuf[t.ulen] = b
			t.ulen++
			t.out = append(t.out, b)
			if t.ulen == t.uneed {
				r, _ := utf8.DecodeRune(t.ubuf[:t.ulen])
				t.uneed, t.ulen = 0, 0
				t.print(r)
			}
			return
		}
		// Truncated sequence.
		t.uneed, t.ulen = 0, 0
		t.print(utf8.RuneError)
	}
	switch {
	case b == 0x1b:
		t.state = stEsc
		t.seq = append(t.seq[:0], b)
		t.inter = t.inter[:0]
	case b < 0x20 || b == 0x7f:
		t.out = append(t.out, b)
		t.control(b)
	case b < 0x80:
		t.out = append(t.out, b)
		t.print(rune(b))
	default:
		t.out = append(t.out, b)
		switch {
		case b&0xe0 == 0xc0:
			t.uneed = 2
		case b&0xf0 == 0xe0:
			t.uneed = 3
		case b&0xf8 == 0xf0:
			t.uneed = 4
		default:
			t.print(utf8.RuneError)
			return
		}
		t.ubuf[0] = b
		t.ulen = 1
	}
}

func (t *term) control(b byte) {
	switch b {
	case 0x07: // BEL
	case 0x08: // BS
		if t.wrapNext {
			t.wrapNext = false
		} else if t.cx > 0 {
			t.cx--
		}
	case 0x09:
		t.tab(1)
	case 0x0a, 0x0b, 0x0c:
		t.lineFeed()
		if t.lnm {
			t.cx = 0
		}
	case 0x0d:
		t.cx, t.wrapNext = 0, false
	case 0x0e:
		t.gl = 1
	case 0x0f:
		t.gl = 0
	}
}

func (t *term) escByte(b byte) {
	switch {
	case b >= 0x20 && b <= 0x2f:
		t.inter = append(t.inter, b)
		return
	case b == 0x18 || b == 0x1a:
		t.flushSeq(true)
		t.state = stGround
		return
	case b == 0x1b:
		t.seq = append(t.seq[:0], b)
		t.inter = t.inter[:0]
		return
	case b < 0x20:
		t.control(b)
		return
	}
	if len(t.inter) == 0 {
		switch b {
		case '[':
			t.state = stCSI
			t.csi = t.csi[:0]
			return
		case ']':
			t.state = stOSC
			t.oscBuf = t.oscBuf[:0]
			return
		case 'P', 'X', '^', '_':
			t.state = stStr
			t.strTyp = b
			t.oscBuf = t.oscBuf[:0]
			return
		}
	}
	t.state = stGround
	keep := true
	if len(t.inter) == 0 {
		switch b {
		case '7':
			t.saveCursor(&t.saved)
		case '8':
			t.restoreCursor(&t.saved)
		case 'D':
			t.lineFeed()
		case 'E':
			t.lineFeed()
			t.cx = 0
		case 'H':
			if t.cx < len(t.tabs) {
				t.tabs[t.cx] = true
			}
		case 'M':
			t.reverseIndex()
		case 'c':
			hist := t.history
			t.reset()
			t.history = hist
			t.title = ""
		case '=':
			t.keypad = true
		case '>':
			t.keypad = false
		}
	} else {
		switch t.inter[0] {
		case '(':
			t.charsets[0] = b
		case ')':
			t.charsets[1] = b
		case '#':
			if b == '8' {
				for y := range t.lines {
					for x := range t.lines[y].cells {
						t.lines[y].cells[x] = cell{r: 'E', w: 1}
					}
				}
			}
		}
	}
	t.flushSeq(keep)
}

func (t *term) csiByte(b byte) {
	switch {
	case b == 0x1b:
		t.seq = append(t.seq[:0], b)
		t.inter = t.inter[:0]
		t.state = stEsc
		return
	case b == 0x18 || b == 0x1a:
		t.flushSeq(true)
		t.state = stGround
		return
	case b < 0x20:
		t.control(b)
		return
	case b >= 0x40 && b <= 0x7e:
		t.state = stGround
		t.flushSeq(t.csiDispatch(b))
		return
	}
	t.csi = append(t.csi, b)
}

// csiParams splits a CSI body: private marker, parameter groups (each a
// list of ':' sub-parameters, -1 = omitted), intermediates.
func parseCSI(body []byte) (priv byte, params [][]int, inter string) {
	i := 0
	if len(body) > 0 && body[0] >= 0x3c && body[0] <= 0x3f {
		priv = body[0]
		i = 1
	}
	j := i
	for j < len(body) && (body[j] >= 0x30 && body[j] <= 0x3b) {
		j++
	}
	inter = string(body[j:])
	ps := body[i:j]
	if len(ps) == 0 {
		return
	}
	for _, g := range bytes.Split(ps, []byte{';'}) {
		var grp []int
		for _, s := range bytes.Split(g, []byte{':'}) {
			if len(s) == 0 {
				grp = append(grp, -1)
				continue
			}
			n, err := strconv.Atoi(string(s))
			if err != nil || n > 1<<20 {
				n = 1 << 20
			}
			grp = append(grp, n)
		}
		params = append(params, grp)
	}
	return
}

func param(ps [][]int, i, def int) int {
	if i < len(ps) && len(ps[i]) > 0 && ps[i][0] >= 0 {
		if ps[i][0] == 0 && def > 0 {
			return def
		}
		return ps[i][0]
	}
	return def
}

// csiDispatch runs one CSI sequence; whether to forward it.
func (t *term) csiDispatch(final byte) bool {
	priv, ps, inter := parseCSI(t.csi)
	switch priv {
	case '?':
		switch {
		case inter == "" && (final == 'h' || final == 'l'):
			for _, g := range ps {
				if len(g) > 0 {
					t.decMode(g[0], final == 'h')
				}
			}
			// ConPTY asks for win32-input-mode; clients must keep sending
			// plain VT (the attach detach key, a Mac terminal).
			if len(ps) == 1 && param(ps, 0, 0) == 9001 {
				return false
			}
			return true
		case inter == "" && final == 'n':
			if param(ps, 0, 0) == 6 {
				x, y := t.cursorReport()
				t.reply("\x1b[?%d;%dR", y, x)
			}
			return false
		case inter == "$" && final == 'p':
			m := param(ps, 0, 0)
			t.reply("\x1b[?%d;%d$y", m, t.decModeState(m))
			return false
		case inter == "" && final == 'u':
			return false // kitty keyboard query: unsupported, like an old terminal
		case final == 'J' || final == 'K':
			t.csiNormal(final, ps, inter)
		}
		return true
	case '>':
		switch final {
		case 'c':
			t.reply("\x1b[>84;0;0c")
			return false
		case 'q':
			return false // XTVERSION
		}
		return true
	case '=':
		return final != 'c'
	case '<':
		return true
	}
	return t.csiNormal(final, ps, inter)
}

func (t *term) csiNormal(final byte, ps [][]int, inter string) bool {
	if inter != "" {
		switch {
		case inter == "!" && final == 'p': // DECSTR
			t.insert, t.origin, t.autowrap, t.cursorVisible = false, false, true, true
			t.cursorKeys, t.keypad = false, false
			t.top, t.bot = 0, t.rows-1
			t.pen = attr{}
			t.charsets, t.gl = [2]byte{'B', 'B'}, 0
			t.saved = savedCursor{}
		case inter == "$" && final == 'p': // DECRQM (ANSI)
			m := param(ps, 0, 0)
			st := 0
			switch m {
			case 4:
				st = b2s(t.insert)
			case 20:
				st = b2s(t.lnm)
			}
			t.reply("\x1b[%d;%d$y", m, st)
			return false
		}
		return true
	}
	n := param(ps, 0, 1)
	switch final {
	case '@':
		t.insertChars(n)
	case 'A':
		t.moveTo(t.cx, t.clampUp(t.cy-n))
	case 'B', 'e':
		t.moveTo(t.cx, t.clampDown(t.cy+n))
	case 'C', 'a':
		t.moveTo(t.cx+n, t.cy)
	case 'D':
		t.moveTo(t.cx-n, t.cy)
	case 'E':
		t.moveTo(0, t.clampDown(t.cy+n))
	case 'F':
		t.moveTo(0, t.clampUp(t.cy-n))
	case 'G', '`':
		t.moveTo(n-1, t.cy)
	case 'H', 'f':
		row, col := param(ps, 0, 1), param(ps, 1, 1)
		t.cup(row-1, col-1)
	case 'I':
		t.tab(n)
	case 'J':
		t.eraseDisplay(param(ps, 0, 0))
	case 'K':
		t.eraseLine(param(ps, 0, 0))
	case 'L':
		t.insertLines(n)
	case 'M':
		t.deleteLines(n)
	case 'P':
		t.deleteChars(n)
	case 'S':
		t.scrollUp(t.top, t.bot, n)
	case 'T':
		if len(ps) <= 1 {
			t.scrollDown(t.top, t.bot, n)
		}
	case 'X':
		t.eraseChars(n)
	case 'Z':
		t.tab(-n)
	case 'b':
		if t.lastChar != 0 {
			for i := 0; i < n && i < 65536; i++ {
				t.print(t.lastChar)
			}
		}
	case 'c':
		if param(ps, 0, 0) == 0 {
			t.reply("\x1b[?1;2c")
		}
		return false
	case 'd':
		t.cup(n-1, t.cx)
	case 'g':
		switch param(ps, 0, 0) {
		case 0:
			if t.cx < len(t.tabs) {
				t.tabs[t.cx] = false
			}
		case 3:
			for i := range t.tabs {
				t.tabs[i] = false
			}
		}
	case 'h', 'l':
		for _, g := range ps {
			if len(g) == 0 {
				continue
			}
			switch g[0] {
			case 4:
				t.insert = final == 'h'
			case 20:
				t.lnm = final == 'h'
			}
		}
	case 'm':
		t.sgr(ps)
	case 'n':
		switch param(ps, 0, 0) {
		case 5:
			t.reply("\x1b[0n")
		case 6:
			x, y := t.cursorReport()
			t.reply("\x1b[%d;%dR", y, x)
		}
		return false
	case 'r':
		top, bot := param(ps, 0, 1)-1, param(ps, 1, t.rows)-1
		if bot >= t.rows {
			bot = t.rows - 1
		}
		if top < bot {
			t.top, t.bot = top, bot
			t.cup(0, 0)
		}
	case 's':
		if len(ps) == 0 {
			t.saveCursor(&t.saved)
		}
	case 'u':
		if len(ps) == 0 {
			t.restoreCursor(&t.saved)
		}
	case 't':
		switch param(ps, 0, 0) {
		case 11, 13, 14, 15, 16, 18, 19, 20, 21:
			return false // window reports
		}
	}
	return true
}

func b2s(b bool) int {
	if b {
		return 1
	}
	return 2
}

func (t *term) decModeState(m int) int {
	switch m {
	case 1:
		return b2s(t.cursorKeys)
	case 6:
		return b2s(t.origin)
	case 7:
		return b2s(t.autowrap)
	case 25:
		return b2s(t.cursorVisible)
	case 47, 1047, 1049:
		return b2s(t.alt)
	case 1004:
		return b2s(t.focus)
	case 2004:
		return b2s(t.bracketed)
	case 9, 1000, 1002, 1003, 1005, 1006, 1015, 1016:
		return b2s(t.mouse[m])
	}
	return 0
}

func (t *term) decMode(m int, on bool) {
	switch m {
	case 1:
		t.cursorKeys = on
	case 6:
		t.origin = on
		t.cup(0, 0)
	case 7:
		t.autowrap = on
	case 25:
		t.cursorVisible = on
	case 47, 1047, 1049:
		t.setAlt(on, m)
	case 1048:
		if on {
			t.saveCursor(&t.saved)
		} else {
			t.restoreCursor(&t.saved)
		}
	case 1004:
		t.focus = on
	case 2004:
		t.bracketed = on
	case 9, 1000, 1002, 1003, 1005, 1006, 1015, 1016:
		if on {
			t.mouse[m] = true
		} else {
			delete(t.mouse, m)
		}
	}
}

func (t *term) setAlt(on bool, mode int) {
	if on == t.alt {
		if on && mode != 47 {
			for i := range t.lines {
				t.lines[i] = t.blankLine(attr{})
			}
		}
		return
	}
	if on {
		if mode == 1049 {
			t.saveCursor(&t.altCursor)
		}
		t.mainLines = t.lines
		t.lines = make([]line, t.rows)
		for i := range t.lines {
			t.lines[i] = t.blankLine(attr{})
		}
		t.alt = true
		return
	}
	t.lines = t.mainLines
	t.mainLines = nil
	t.alt = false
	t.fitLines()
	if mode == 1049 {
		t.restoreCursor(&t.altCursor)
	}
}

// fitLines makes the visible lines match the current size (after a resize
// while the other screen was up).
func (t *term) fitLines() {
	for len(t.lines) < t.rows {
		t.lines = append(t.lines, t.blankLine(attr{}))
	}
	if len(t.lines) > t.rows {
		t.lines = t.lines[:t.rows]
	}
	for i := range t.lines {
		t.lines[i] = t.fitLine(t.lines[i])
	}
}

func (t *term) fitLine(l line) line {
	if len(l.cells) == t.cols {
		return l
	}
	if len(l.cells) > t.cols {
		l.cells = l.cells[:t.cols:t.cols]
		if t.cols > 0 && l.cells[t.cols-1].w == 2 {
			l.cells[t.cols-1] = blankCell(attr{})
		}
		return l
	}
	n := make([]cell, t.cols)
	copy(n, l.cells)
	for i := len(l.cells); i < t.cols; i++ {
		n[i] = blankCell(attr{})
	}
	l.cells = n
	return l
}

func (t *term) saveCursor(s *savedCursor) {
	*s = savedCursor{x: t.cx, y: t.cy, pen: t.pen, origin: t.origin, charsets: t.charsets, gl: t.gl, wrapNext: t.wrapNext, set: true}
}

func (t *term) restoreCursor(s *savedCursor) {
	if !s.set {
		t.cx, t.cy, t.wrapNext = 0, 0, false
		t.pen, t.origin = attr{}, false
		return
	}
	t.cx, t.cy, t.pen, t.origin, t.charsets, t.gl, t.wrapNext = s.x, s.y, s.pen, s.origin, s.charsets, s.gl, s.wrapNext
	t.clampCursor()
}

func (t *term) clampCursor() {
	if t.cx >= t.cols {
		t.cx = t.cols - 1
	}
	if t.cy >= t.rows {
		t.cy = t.rows - 1
	}
	if t.cx < 0 {
		t.cx = 0
	}
	if t.cy < 0 {
		t.cy = 0
	}
}

func (t *term) cursorReport() (x, y int) {
	y = t.cy + 1
	if t.origin {
		y -= t.top
	}
	return t.cx + 1, y
}

func (t *term) moveTo(x, y int) {
	t.cx, t.cy, t.wrapNext = x, y, false
	t.clampCursor()
}

func (t *term) cup(row, col int) {
	if t.origin {
		row += t.top
		if row > t.bot {
			row = t.bot
		}
	}
	t.moveTo(col, row)
}

func (t *term) clampUp(y int) int {
	if t.cy >= t.top && y < t.top {
		return t.top
	}
	return y
}

func (t *term) clampDown(y int) int {
	if t.cy <= t.bot && y > t.bot {
		return t.bot
	}
	return y
}

func (t *term) tab(n int) {
	t.wrapNext = false
	for n > 0 {
		x := t.cx + 1
		for x < t.cols-1 && !t.tabs[x] {
			x++
		}
		if x >= t.cols {
			x = t.cols - 1
		}
		t.cx = x
		n--
	}
	for n < 0 {
		x := t.cx - 1
		for x > 0 && !t.tabs[x] {
			x--
		}
		if x < 0 {
			x = 0
		}
		t.cx = x
		n++
	}
}

func (t *term) lineFeed() {
	t.wrapNext = false
	if t.cy == t.bot {
		t.scrollUp(t.top, t.bot, 1)
	} else if t.cy < t.rows-1 {
		t.cy++
	}
}

func (t *term) reverseIndex() {
	t.wrapNext = false
	if t.cy == t.top {
		t.scrollDown(t.top, t.bot, 1)
	} else if t.cy > 0 {
		t.cy--
	}
}

func (t *term) pushHistory(l line) {
	if t.histMax <= 0 {
		return
	}
	// Keep only the written part: most lines are much shorter than the
	// screen, and history is 10 000 of them.
	n := len(l.cells)
	for n > 0 && l.cells[n-1].r == 0 && l.cells[n-1].w == 1 && l.cells[n-1].a == (attr{}) {
		n--
	}
	c := make([]cell, n)
	copy(c, l.cells[:n])
	t.history = append(t.history, line{cells: c, wrapped: l.wrapped})
	if len(t.history) > t.histMax+t.histMax/8+16 {
		keep := make([]line, t.histMax)
		copy(keep, t.history[len(t.history)-t.histMax:])
		t.history = keep
	}
}

// trimHistory enforces the exact limit (capture reads it).
func (t *term) hist() []line {
	if len(t.history) > t.histMax {
		return t.history[len(t.history)-t.histMax:]
	}
	return t.history
}

func (t *term) scrollUp(top, bot, n int) {
	if n <= 0 {
		return
	}
	if n > bot-top+1 {
		n = bot - top + 1
	}
	if top == 0 && !t.alt {
		for i := 0; i < n; i++ {
			t.pushHistory(t.lines[i])
		}
	}
	copy(t.lines[top:bot+1], t.lines[top+n:bot+1])
	for y := bot - n + 1; y <= bot; y++ {
		t.lines[y] = t.blankLine(t.pen)
	}
}

func (t *term) scrollDown(top, bot, n int) {
	if n <= 0 {
		return
	}
	if n > bot-top+1 {
		n = bot - top + 1
	}
	copy(t.lines[top+n:bot+1], t.lines[top:bot+1-n])
	for y := top; y < top+n; y++ {
		t.lines[y] = t.blankLine(t.pen)
	}
}

func (t *term) insertLines(n int) {
	if t.cy < t.top || t.cy > t.bot {
		return
	}
	t.scrollDown(t.cy, t.bot, n)
	t.cx, t.wrapNext = 0, false
}

func (t *term) deleteLines(n int) {
	if t.cy < t.top || t.cy > t.bot {
		return
	}
	if n > t.bot-t.cy+1 {
		n = t.bot - t.cy + 1
	}
	copy(t.lines[t.cy:t.bot+1], t.lines[t.cy+n:t.bot+1])
	for y := t.bot - n + 1; y <= t.bot; y++ {
		t.lines[y] = t.blankLine(t.pen)
	}
	t.cx, t.wrapNext = 0, false
}

// clearCells blanks [x0, x1) of row y, fixing up wide chars cut in half.
func (t *term) clearCells(y, x0, x1 int) {
	l := t.lines[y].cells
	if x0 < 0 {
		x0 = 0
	}
	if x1 > len(l) {
		x1 = len(l)
	}
	if x0 >= x1 {
		return
	}
	if x0 > 0 && l[x0].w == 0 {
		l[x0-1] = blankCell(t.pen)
	}
	if x1 < len(l) && l[x1].w == 0 {
		l[x1] = blankCell(t.pen)
	}
	for x := x0; x < x1; x++ {
		l[x] = blankCell(t.pen)
	}
}

func (t *term) eraseLine(mode int) {
	switch mode {
	case 0:
		t.clearCells(t.cy, t.cx, t.cols)
		t.lines[t.cy].wrapped = false
	case 1:
		t.clearCells(t.cy, 0, t.cx+1)
	case 2:
		t.clearCells(t.cy, 0, t.cols)
		t.lines[t.cy].wrapped = false
	}
}

func (t *term) eraseDisplay(mode int) {
	switch mode {
	case 0:
		t.eraseLine(0)
		for y := t.cy + 1; y < t.rows; y++ {
			t.lines[y] = t.blankLine(t.pen)
		}
	case 1:
		for y := 0; y < t.cy; y++ {
			t.lines[y] = t.blankLine(t.pen)
		}
		t.clearCells(t.cy, 0, t.cx+1)
	case 2:
		// tmux's scroll-on-clear (default on): a whole-screen clear of the
		// main screen first scrolls what was on it into history.
		if !t.alt {
			last := -1
			for y := t.rows - 1; y >= 0; y-- {
				if !lineEmpty(t.lines[y]) {
					last = y
					break
				}
			}
			for y := 0; y <= last; y++ {
				t.pushHistory(t.lines[y])
			}
		}
		for y := 0; y < t.rows; y++ {
			t.lines[y] = t.blankLine(t.pen)
		}
	case 3:
		t.history = nil
	}
}

func lineEmpty(l line) bool {
	for _, c := range l.cells {
		if c.r != 0 || c.a.bg != 0 {
			return false
		}
	}
	return true
}

func (t *term) eraseChars(n int) {
	t.clearCells(t.cy, t.cx, t.cx+n)
}

func (t *term) insertChars(n int) {
	l := t.lines[t.cy].cells
	if t.cx >= len(l) {
		return
	}
	if n > len(l)-t.cx {
		n = len(l) - t.cx
	}
	copy(l[t.cx+n:], l[t.cx:len(l)-n])
	for x := t.cx; x < t.cx+n; x++ {
		l[x] = blankCell(t.pen)
	}
	if l[len(l)-1].w == 2 {
		l[len(l)-1] = blankCell(t.pen)
	}
	if t.cx+n < len(l) && l[t.cx+n].w == 0 {
		l[t.cx+n] = blankCell(t.pen)
	}
	t.wrapNext = false
}

func (t *term) deleteChars(n int) {
	l := t.lines[t.cy].cells
	if t.cx >= len(l) {
		return
	}
	if n > len(l)-t.cx {
		n = len(l) - t.cx
	}
	if t.cx > 0 && l[t.cx].w == 0 {
		l[t.cx-1] = blankCell(t.pen)
	}
	copy(l[t.cx:], l[t.cx+n:])
	for x := len(l) - n; x < len(l); x++ {
		l[x] = blankCell(t.pen)
	}
	if l[t.cx].w == 0 {
		l[t.cx] = blankCell(t.pen)
	}
	t.wrapNext = false
}

var lineDrawing = map[rune]rune{
	'`': '◆', 'a': '▒', 'b': '␉', 'c': '␌', 'd': '␍', 'e': '␊', 'f': '°', 'g': '±',
	'h': '␤', 'i': '␋', 'j': '┘', 'k': '┐', 'l': '┌', 'm': '└', 'n': '┼', 'o': '⎺',
	'p': '⎻', 'q': '─', 'r': '⎼', 's': '⎽', 't': '├', 'u': '┤', 'v': '┴', 'w': '┬',
	'x': '│', 'y': '≤', 'z': '≥', '{': 'π', '|': '≠', '}': '£', '~': '·',
}

func (t *term) print(r rune) {
	if t.charsets[t.gl] == '0' {
		if m, ok := lineDrawing[r]; ok {
			r = m
		}
	}
	w := runeWidth(r)
	if w == 0 {
		t.combine(r)
		return
	}
	if t.wrapNext {
		if t.autowrap {
			t.lines[t.cy].wrapped = true
			t.lineFeed()
			t.cx = 0
		}
		t.wrapNext = false
	}
	if w == 2 && t.cx == t.cols-1 {
		if t.cols < 2 {
			return
		}
		if !t.autowrap {
			return
		}
		t.clearCells(t.cy, t.cx, t.cx+1)
		t.lines[t.cy].wrapped = true
		t.lineFeed()
		t.cx = 0
	}
	if t.insert {
		t.insertChars(w)
	}
	l := t.lines[t.cy].cells
	t.clearCells(t.cy, t.cx, t.cx+w)
	l[t.cx] = cell{r: r, w: uint8(w), a: t.pen}
	if w == 2 {
		l[t.cx+1] = cell{w: 0, a: t.pen}
	}
	t.lastChar = r
	if t.cx+w >= t.cols {
		t.cx = t.cols - 1
		t.wrapNext = true
	} else {
		t.cx += w
	}
}

// combine attaches a zero-width rune to the cell before the cursor.
func (t *term) combine(r rune) {
	x, y := t.cx-1, t.cy
	if t.wrapNext {
		x = t.cx
	}
	if x < 0 {
		return
	}
	l := t.lines[y].cells
	if l[x].w == 0 && x > 0 {
		x--
	}
	c := &l[x]
	if c.r == 0 {
		return
	}
	s := t.cellText(*c) + string(r)
	if len(s) > 64 {
		return
	}
	idx, ok := t.combIdx[s]
	if !ok {
		if len(t.combs) >= 1<<16 {
			return
		}
		idx = len(t.combs)
		t.combs = append(t.combs, s)
		t.combIdx[s] = idx
	}
	c.r = combBase + rune(idx)
}

func (t *term) cellText(c cell) string {
	if c.r >= combBase {
		if i := int(c.r - combBase); i < len(t.combs) {
			return t.combs[i]
		}
		return " "
	}
	if c.r == 0 {
		return " "
	}
	return string(c.r)
}

func (t *term) sgr(ps [][]int) {
	if len(ps) == 0 {
		t.pen = attr{}
		return
	}
	for i := 0; i < len(ps); i++ {
		g := ps[i]
		p := g[0]
		if p < 0 {
			p = 0
		}
		switch {
		case p == 0:
			t.pen = attr{}
		case p == 1:
			t.pen.fl |= aBold
		case p == 2:
			t.pen.fl |= aDim
		case p == 3:
			t.pen.fl |= aItalic
		case p == 4:
			if len(g) > 1 && g[1] == 0 {
				t.pen.fl &^= aUnderline | aDoubleUnderline
			} else {
				t.pen.fl |= aUnderline
			}
		case p == 5 || p == 6:
			t.pen.fl |= aBlink
		case p == 7:
			t.pen.fl |= aReverse
		case p == 8:
			t.pen.fl |= aHidden
		case p == 9:
			t.pen.fl |= aStrike
		case p == 21:
			t.pen.fl |= aDoubleUnderline
		case p == 22:
			t.pen.fl &^= aBold | aDim
		case p == 23:
			t.pen.fl &^= aItalic
		case p == 24:
			t.pen.fl &^= aUnderline | aDoubleUnderline
		case p == 25:
			t.pen.fl &^= aBlink
		case p == 27:
			t.pen.fl &^= aReverse
		case p == 28:
			t.pen.fl &^= aHidden
		case p == 29:
			t.pen.fl &^= aStrike
		case p >= 30 && p <= 37:
			t.pen.fg = uint32(p-30) + 1
		case p == 38 || p == 48 || p == 58:
			c, used := extColor(ps, i)
			i += used
			if p == 38 {
				t.pen.fg = c
			} else if p == 48 {
				t.pen.bg = c
			}
		case p == 39:
			t.pen.fg = 0
		case p >= 40 && p <= 47:
			t.pen.bg = uint32(p-40) + 1
		case p == 49:
			t.pen.bg = 0
		case p == 53:
			t.pen.fl |= aOverline
		case p == 55:
			t.pen.fl &^= aOverline
		case p >= 90 && p <= 97:
			t.pen.fg = uint32(p-90+8) + 1
		case p >= 100 && p <= 107:
			t.pen.bg = uint32(p-100+8) + 1
		}
	}
}

// extColor parses 38/48 colour forms at ps[i]; the colour and how many
// extra groups it consumed.
func extColor(ps [][]int, i int) (uint32, int) {
	g := ps[i]
	clamp := func(v int) uint32 {
		if v < 0 {
			return 0
		}
		if v > 255 {
			return 255
		}
		return uint32(v)
	}
	if len(g) > 1 { // colon form
		switch g[1] {
		case 5:
			if len(g) > 2 {
				return clamp(g[2]) + 1, 0
			}
		case 2:
			v := g[2:]
			if len(v) >= 4 { // with colour-space id
				v = v[1:]
			}
			if len(v) >= 3 {
				return colRGB | clamp(v[0])<<16 | clamp(v[1])<<8 | clamp(v[2]), 0
			}
		}
		return 0, 0
	}
	if i+1 >= len(ps) {
		return 0, 0
	}
	switch ps[i+1][0] {
	case 5:
		if i+2 < len(ps) {
			return clamp(ps[i+2][0]) + 1, 2
		}
		return 0, 1
	case 2:
		if i+4 < len(ps) {
			return colRGB | clamp(ps[i+2][0])<<16 | clamp(ps[i+3][0])<<8 | clamp(ps[i+4][0]), 4
		}
		return 0, len(ps) - 1 - i
	}
	return 0, 1
}

func (t *term) oscDone() {
	t.state = stGround
	s := string(t.oscBuf)
	keep := true
	num, rest, _ := strings.Cut(s, ";")
	switch num {
	case "0", "2":
		t.title = rest
	case "7":
		t.cwd = osc7Path(rest)
	case "4", "10", "11", "12", "13", "14", "15", "16", "17", "19", "104", "110", "111", "112":
		if strings.Contains(rest, "?") {
			keep = false // colour queries: nobody here answers
		}
	case "52":
		if _, data, ok := strings.Cut(rest, ";"); ok && data == "?" {
			keep = false
		}
	}
	t.flushSeq(keep)
}

func (t *term) strDone() {
	t.state = stGround
	keep := true
	if t.strTyp == 'P' {
		s := t.oscBuf
		if bytes.HasPrefix(s, []byte("+q")) || bytes.HasPrefix(s, []byte("$q")) {
			keep = false // XTGETTCAP / DECRQSS queries
		}
	}
	t.flushSeq(keep)
}

// osc7Path turns "file://host/path" into a real path ("/c/Users/x" and
// "/C:/Users/x" become "C:\Users\x" on Windows-style paths).
func osc7Path(s string) string {
	p := s
	if strings.HasPrefix(p, "file://") {
		p = p[len("file://"):]
		if i := strings.IndexByte(p, '/'); i >= 0 {
			p = p[i:]
		} else {
			return ""
		}
	}
	p = percentDecode(p)
	return nativeCwd(p)
}

func percentDecode(s string) string {
	if !strings.Contains(s, "%") {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '%' && i+2 < len(s) {
			if v, err := strconv.ParseUint(s[i+1:i+3], 16, 8); err == nil {
				b.WriteByte(byte(v))
				i += 2
				continue
			}
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

// resize changes the screen size (no reflow: ConPTY and full-screen
// programs repaint after a resize).
func (t *term) resize(cols, rows int) {
	if cols < 1 {
		cols = 1
	}
	if rows < 1 {
		rows = 1
	}
	if cols == t.cols && rows == t.rows {
		return
	}
	oldRows := t.rows
	t.cols = cols
	// Rows first, on the visible screen.
	if rows < oldRows {
		drop := oldRows - rows
		// Blank lines below the cursor go first, then the top scrolls into
		// history (main screen only).
		for y := oldRows - 1; y > t.cy && drop > 0; y-- {
			if !lineEmpty(t.lines[y]) {
				break
			}
			t.lines = t.lines[:y]
			drop--
		}
		if drop > 0 {
			if !t.alt {
				for i := 0; i < drop; i++ {
					t.pushHistory(t.lines[i])
				}
			}
			t.lines = t.lines[drop:]
			t.cy -= drop
		}
	}
	t.rows = rows
	t.fitLines()
	if t.mainLines != nil {
		ml := t.lines
		t.lines = t.mainLines
		t.fitLines()
		t.mainLines = t.lines
		t.lines = ml
	}
	t.top, t.bot = 0, t.rows-1
	t.wrapNext = false
	t.clampCursor()
	t.resetTabs()
}
