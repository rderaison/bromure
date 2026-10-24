package panes

import (
	"strings"
	"testing"
)

func feed(t *term, s string) { t.write([]byte(s)) }

func ip(n int) *int { return &n }

func TestCaptureVisibleKeepsBlankLines(t *testing.T) {
	tm := newTerm(10, 4, 100)
	feed(tm, "hello\r\nworld")
	if got, want := tm.capture(CaptureOptions{}), "hello\nworld\n\n\n"; got != want {
		t.Fatalf("capture %q, want %q", got, want)
	}
}

func TestCaptureJoinAndTrailingSpaces(t *testing.T) {
	tm := newTerm(10, 4, 100)
	feed(tm, "abcdefghijKLM\r\nab   ")
	if got, want := tm.capture(CaptureOptions{}), "abcdefghij\nKLM\nab\n\n"; got != want {
		t.Errorf("-p %q, want %q", got, want)
	}
	if got, want := tm.capture(CaptureOptions{Join: true}), "abcdefghijKLM\nab   \n\n"; got != want {
		t.Errorf("-J %q, want %q", got, want)
	}
	// An erased tail is not "written": -J leaves it out.
	feed(tm, "\r\x1b[K")
	if got, want := tm.capture(CaptureOptions{Join: true}), "abcdefghijKLM\n\n\n"; got != want {
		t.Errorf("-J after EL %q, want %q", got, want)
	}
}

func TestCaptureHistoryRanges(t *testing.T) {
	tm := newTerm(10, 3, 100)
	feed(tm, "1\r\n2\r\n3\r\n4\r\n5")
	cases := []struct {
		name string
		o    CaptureOptions
		want string
	}{
		{"visible", CaptureOptions{}, "3\n4\n5\n"},
		{"-S -", CaptureOptions{StartHistory: true}, "1\n2\n3\n4\n5\n"},
		{"-S -1", CaptureOptions{Start: ip(-1)}, "2\n3\n4\n5\n"},
		{"-S -100", CaptureOptions{Start: ip(-100)}, "1\n2\n3\n4\n5\n"},
		{"-E 0", CaptureOptions{End: ip(0)}, "3\n"},
		{"-S -2 -E -1", CaptureOptions{Start: ip(-2), End: ip(-1)}, "1\n2\n"},
		{"swapped", CaptureOptions{Start: ip(1), End: ip(0)}, "3\n4\n"},
		{"-E 99 clamps", CaptureOptions{Start: ip(2), End: ip(99)}, "5\n"},
		{"-S 99 clamps", CaptureOptions{Start: ip(99)}, "5\n"},
		{"-E -100", CaptureOptions{StartHistory: true, End: ip(-100)}, "1\n"},
		{"-E -", CaptureOptions{Start: ip(-1), EndVisible: true}, "2\n3\n4\n5\n"},
	}
	for _, c := range cases {
		if got := tm.capture(c.o); got != c.want {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
		}
	}
}

func TestScrollbackLimit(t *testing.T) {
	tm := newTerm(10, 2, 5)
	for i := 0; i < 200; i++ {
		feed(tm, "x\r\n")
	}
	feed(tm, "end")
	got := tm.capture(CaptureOptions{StartHistory: true})
	if n := strings.Count(got, "\n"); n != 7 {
		t.Fatalf("history+visible lines = %d, want 5+2: %q", n, got)
	}
	if !strings.HasSuffix(got, "end\n") {
		t.Fatalf("got %q", got)
	}
}

func TestAltScreen(t *testing.T) {
	tm := newTerm(10, 3, 100)
	feed(tm, "main\r\nsecond")
	feed(tm, "\x1b[?1049h\x1b[Halt")
	if !tm.alt {
		t.Fatal("not on the alternate screen")
	}
	if got := tm.capture(CaptureOptions{}); got != "alt\n\n\n" {
		t.Errorf("alt capture %q", got)
	}
	// Scrolling on the alternate screen adds nothing to history.
	feed(tm, "\r\na\r\nb\r\nc\r\nd")
	if len(tm.history) != 0 {
		t.Errorf("alt screen scrolled into history: %d lines", len(tm.history))
	}
	feed(tm, "\x1b[?1049l")
	if tm.alt {
		t.Fatal("still alt")
	}
	if got := tm.capture(CaptureOptions{}); got != "main\nsecond\n\n" {
		t.Errorf("main capture %q", got)
	}
	if tm.cx != 6 || tm.cy != 1 {
		t.Errorf("cursor not restored: %d,%d", tm.cx, tm.cy)
	}
}

func TestWideChars(t *testing.T) {
	tm := newTerm(10, 3, 100)
	feed(tm, "中文ab")
	if tm.cx != 6 {
		t.Errorf("cursor x %d after two wide + two narrow, want 6", tm.cx)
	}
	if got := tm.capture(CaptureOptions{End: ip(0)}); got != "中文ab\n" {
		t.Errorf("capture %q", got)
	}
	tm2 := newTerm(10, 3, 100)
	feed(tm2, "abcdefghi中😀")
	if got := tm2.capture(CaptureOptions{End: ip(1)}); got != "abcdefghi\n中😀\n" {
		t.Errorf("wide at the margin: %q", got)
	}
	if got := tm2.capture(CaptureOptions{Join: true, End: ip(1)}); got != "abcdefghi中😀\n" {
		t.Errorf("wide at the margin -J: %q", got)
	}
	// Overwriting half a wide char blanks the other half.
	tm3 := newTerm(10, 1, 0)
	feed(tm3, "中\x1b[1;2Hx")
	if got := tm3.capture(CaptureOptions{}); got != " x\n" {
		t.Errorf("half overwrite %q", got)
	}
	// Combining marks join their base cell.
	tm4 := newTerm(10, 1, 0)
	feed(tm4, "e\u0301x")
	if got := tm4.capture(CaptureOptions{}); got != "e\u0301x\n" || tm4.cx != 2 {
		t.Errorf("combining %q cx %d", got, tm4.cx)
	}
}

func TestModes(t *testing.T) {
	tm := newTerm(80, 24, 100)
	feed(tm, "\x1b[?2004h\x1b[?1h\x1b[?25l\x1b[?1000;1006h")
	if !tm.bracketed || !tm.cursorKeys || tm.cursorVisible || !tm.mouse[1000] || !tm.mouse[1006] {
		t.Fatalf("modes: bracketed %v ck %v visible %v mouse %v", tm.bracketed, tm.cursorKeys, tm.cursorVisible, tm.mouse)
	}
	feed(tm, "\x1b[?2004l\x1b[?25h")
	if tm.bracketed || !tm.cursorVisible {
		t.Fatal("modes not reset")
	}
}

func TestTitleAndCwd(t *testing.T) {
	tm := newTerm(80, 24, 100)
	feed(tm, "\x1b]0;first\x07\x1b]2;second\x1b\\\x1b]7;file://host/home/you/src%20x\x07")
	if tm.title != "second" {
		t.Errorf("title %q", tm.title)
	}
	want := "/home/you/src x"
	if nc := nativeCwd(want); nc != want {
		want = nc
	}
	if tm.cwd != want {
		t.Errorf("cwd %q want %q", tm.cwd, want)
	}
}

func TestOutputFilterAndReplies(t *testing.T) {
	tm := newTerm(80, 24, 100)
	in := "\x1b[?9001h\x1b[?1004hhello \x1b[31mred\x1b[0m\x1b[c\x1b[6n\x1b]11;?\x07\x1bP+q544e\x1b\\ok"
	tm.write([]byte(in[:13]))
	tm.write([]byte(in[13:]))
	out := string(tm.takeOutput())
	if want := "\x1b[?1004hhello \x1b[31mred\x1b[0mok"; out != want {
		t.Errorf("forwarded %q, want %q", out, want)
	}
	rep := string(tm.takeReplies())
	if want := "\x1b[?1;2c\x1b[1;10R"; rep != want {
		t.Errorf("replies %q, want %q", rep, want)
	}
}

func TestCaptureEscapes(t *testing.T) {
	tm := newTerm(20, 1, 0)
	feed(tm, "\x1b[1;31mred\x1b[0m plain \x1b[2;38;5;244mdim")
	got := tm.capture(CaptureOptions{Escapes: true})
	// The never-written tail has default attributes: tmux writes the reset
	// before trimming the spaces.
	want := "\x1b[1;31mred\x1b[0m plain \x1b[2;38;5;244mdim\x1b[0m\n"
	if got != want {
		t.Errorf("-e %q, want %q", got, want)
	}
	tm2 := newTerm(20, 1, 0)
	feed(tm2, "\x1b[38;2;10;20;30;48:5:4mx")
	if got := tm2.capture(CaptureOptions{Escapes: true}); got != "\x1b[38;2;10;20;30;44mx\x1b[39;49m\n" {
		t.Errorf("rgb %q", got)
	}
}

func TestClearScreenScrollsIntoHistory(t *testing.T) {
	tm := newTerm(10, 3, 100)
	feed(tm, "a\r\nb\x1b[2J\x1b[Hc")
	if got := tm.capture(CaptureOptions{StartHistory: true}); got != "a\nb\nc\n\n\n" {
		t.Errorf("got %q", got)
	}
	feed(tm, "\x1b[3J")
	if got := tm.capture(CaptureOptions{StartHistory: true}); got != "c\n\n\n" {
		t.Errorf("after ED 3: %q", got)
	}
}

func TestScrollRegionAndEditing(t *testing.T) {
	tm := newTerm(10, 4, 100)
	feed(tm, "1\r\n2\r\n3\r\n4")
	feed(tm, "\x1b[2;3r\x1b[3;1H\n") // LF at the region's bottom scrolls 2..3 only
	if got := tm.capture(CaptureOptions{}); got != "1\n3\n\n4\n" {
		t.Errorf("region scroll %q", got)
	}
	if len(tm.history) != 0 {
		t.Error("a region scroll went into history")
	}
	tm2 := newTerm(10, 1, 0)
	feed(tm2, "abcdef\x1b[1;2H\x1b[2P\x1b[1@Z")
	if got := tm2.capture(CaptureOptions{}); got != "aZdef\n" {
		t.Errorf("DCH/ICH %q", got)
	}
}

// A repaint fed to a fresh terminal reproduces the screen and its modes.
func TestRepaintRoundTrip(t *testing.T) {
	src := newTerm(30, 6, 100)
	feed(src, "\x1b[1mbold\x1b[0m line\r\n\x1b[44m blue bg \x1b[0m 中文\r\n")
	feed(src, "\x1b[?2004h\x1b[?1h\x1b[?1000h\x1b[?1049h\x1b[3;5H\x1b[7malt\x1b[0m screen")
	feed(src, "\x1b[2;5r\x1b[4;2H\x1b[32m")
	dst := newTerm(30, 6, 100)
	dst.write(src.repaint())
	for _, o := range []CaptureOptions{{}, {Escapes: true}, {Join: true}} {
		if a, b := src.capture(o), dst.capture(o); a != b {
			t.Errorf("capture %+v differs:\n src %q\n dst %q", o, a, b)
		}
	}
	if dst.alt != src.alt || dst.bracketed != src.bracketed || dst.cursorKeys != src.cursorKeys ||
		!dst.mouse[1000] || dst.cx != src.cx || dst.cy != src.cy || dst.top != src.top || dst.bot != src.bot ||
		dst.pen != src.pen || dst.cursorVisible != src.cursorVisible {
		t.Errorf("state differs: dst alt=%v bp=%v ck=%v cur=%d,%d region=%d-%d pen=%+v", dst.alt, dst.bracketed,
			dst.cursorKeys, dst.cx, dst.cy, dst.top, dst.bot, dst.pen)
	}
	// Leaving the alternate screen shows the same main screen on both.
	feed(src, "\x1b[?1049l")
	feed(dst, "\x1b[?1049l")
	if a, b := src.capture(CaptureOptions{Escapes: true}), dst.capture(CaptureOptions{Escapes: true}); a != b {
		t.Errorf("main screen differs after leaving alt:\n src %q\n dst %q", a, b)
	}
}

func TestResize(t *testing.T) {
	tm := newTerm(10, 4, 100)
	feed(tm, "1\r\n2\r\n3\r\n4")
	tm.resize(5, 2)
	if got := tm.capture(CaptureOptions{StartHistory: true}); got != "1\n2\n3\n4\n" {
		t.Errorf("after shrink %q", got)
	}
	if tm.cy != 1 {
		t.Errorf("cursor y %d", tm.cy)
	}
	tm.resize(20, 5)
	if got := tm.capture(CaptureOptions{}); got != "3\n4\n\n\n\n" {
		t.Errorf("after grow %q", got)
	}
}

func TestKeys(t *testing.T) {
	cases := []struct {
		key  string
		ck   bool
		want string
	}{
		{"Enter", false, "\r"}, {"enter", false, "\r"}, {"Escape", false, "\x1b"}, {"Tab", false, "\t"},
		{"BTab", false, "\x1b[Z"}, {"BSpace", false, "\x7f"}, {"Space", false, " "},
		{"Up", false, "\x1b[A"}, {"Up", true, "\x1bOA"}, {"Down", false, "\x1b[B"}, {"Left", false, "\x1b[D"},
		{"Right", true, "\x1bOC"}, {"Home", false, "\x1b[1~"}, {"End", false, "\x1b[4~"},
		{"PPage", false, "\x1b[5~"}, {"PageUp", false, "\x1b[5~"}, {"NPage", false, "\x1b[6~"}, {"PageDown", false, "\x1b[6~"},
		{"DC", false, "\x1b[3~"}, {"IC", false, "\x1b[2~"},
		{"F1", false, "\x1bOP"}, {"F4", false, "\x1bOS"}, {"F5", false, "\x1b[15~"}, {"F12", false, "\x1b[24~"},
		{"C-c", false, "\x03"}, {"C-a", false, "\x01"}, {"C-[", false, "\x1b"}, {"^C", false, "\x03"},
		{"C-Space", false, "\x00"}, {"M-x", false, "\x1bx"}, {"M-Enter", false, "\x1b\r"},
		{"C-M-a", false, "\x1b\x01"}, {"S-Up", false, "\x1b[1;2A"}, {"C-Up", false, "\x1b[1;5A"},
		{"M-Left", true, "\x1b[1;3D"}, {"C-F5", false, "\x1b[15;5~"}, {"S-F1", false, "\x1b[1;2P"},
		{"a", false, "a"}, {"hello", false, "hello"}, {"y", false, "y"}, {"/exit", false, "/exit"},
		{"Enter2", false, "Enter2"}, {"é", false, "é"}, {"U+263A", false, "☺"},
	}
	for _, c := range cases {
		if got := translateKey(c.key, c.ck); got != c.want {
			t.Errorf("%q (ck=%v) = %q, want %q", c.key, c.ck, got, c.want)
		}
	}
}

func TestPosixArgs(t *testing.T) {
	cases := map[string]string{
		`"C:\Program Files\nodejs\node.exe" C:\Users\you\AppData\Roaming\npm\node_modules\@anthropic-ai\claude-code\cli.js --resume`: `node C:\Users\you\AppData\Roaming\npm\node_modules\@anthropic-ai\claude-code\cli.js --resume`,
		`C:\Program\bash.exe -l`:    `bash -l`,
		`claude.exe`:                `claude`,
		`"C:\x y\cmd.exe" /c "a b"`: `cmd /c "a b"`,
	}
	for in, want := range cases {
		if got := posixArgs(in); got != want {
			t.Errorf("posixArgs(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestBuildTableForeground(t *testing.T) {
	mk := func(pid, ppid int, exe string, sec int) *procInfo {
		return &procInfo{pid: pid, ppid: ppid, exe: exe, args: exe}
	}
	// bash → node (the agent) → rg; plus a conhost helper.
	ps := []*procInfo{mk(10, 1, "bash", 0), mk(20, 10, "node", 1), mk(30, 20, "rg", 2), mk(40, 10, "conhost", 0)}
	ps[1].start = ps[0].start.Add(1)
	ps[2].start = ps[0].start.Add(2)
	got := buildTable(3, "/dev/pty/bromure-3", 10, ps)
	if len(got) != 3 {
		t.Fatalf("rows %+v", got)
	}
	order := []int{got[0].PID, got[1].PID, got[2].PID}
	if order[0] != 10 || order[1] != 20 || order[2] != 30 {
		t.Errorf("order %v", order)
	}
	if got[0].Foreground || !got[1].Foreground || !got[2].Foreground {
		t.Errorf("foreground marks %+v", got)
	}
	// An idle shell is its own foreground.
	got = buildTable(0, "t", 10, []*procInfo{mk(10, 1, "bash", 0)})
	if !got[0].Foreground {
		t.Error("idle shell not foreground")
	}
	// Git Bash: root bash, a forked bash, and the program whose parent
	// (an exec stub) isn't in the job.
	orphan := []*procInfo{mk(10, 1, "bash", 0), mk(11, 10, "bash", 0), mk(30, 99, "sleep", 0)}
	orphan[1].start = orphan[0].start.Add(1)
	orphan[2].start = orphan[0].start.Add(2)
	got = buildTable(0, "t", 10, orphan)
	if len(got) != 3 || got[0].PID != 10 || got[0].Foreground || got[1].Foreground || !got[2].Foreground || got[2].PID != 30 {
		t.Errorf("orphaned program %+v", got)
	}
	// A non-shell root is the foreground with its children.
	got = buildTable(0, "t", 5, []*procInfo{mk(5, 1, "claude", 0), mk(6, 5, "bash", 0)})
	if !got[0].Foreground || !got[1].Foreground {
		t.Errorf("non-shell root %+v", got)
	}
}
