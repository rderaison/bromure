package transcripts

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func write(t *testing.T, content string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "t.jsonl")
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestFirstReadAlignsToLine(t *testing.T) {
	// 3 lines of 10 bytes each ("aaaaaaaaa\n"…).
	content := strings.Repeat("a", 9) + "\n" + strings.Repeat("b", 9) + "\n" + strings.Repeat("c", 9) + "\n"
	p := write(t, content)
	// Window 15: s0 = 15, inside line 2 → aligned back to its start (10).
	c, ok := Read(p, "", 0, 15, "tail")
	if !ok || c.Size != 30 || c.Start != 10 || c.End != 30 || string(c.Bytes) != content[10:] {
		t.Fatalf("got %+v %q", c, c.Bytes)
	}
}

func TestTailIncremental(t *testing.T) {
	content := "line1\nline2\npartial"
	p := write(t, content)
	// Known file at offset 6: from there to the last complete line.
	c, _ := Read(p, p, 6, 1000, "tail")
	if c.Start != 6 || c.End != 12 || string(c.Bytes) != "line2\n" {
		t.Fatalf("got %+v %q", c, c.Bytes)
	}
	// Another path known: fresh read from the end.
	c, _ = Read(p, "/other", 6, 1000, "tail")
	if c.Start != 0 || c.End != 12 {
		t.Fatalf("fresh: %+v", c)
	}
}

func TestTailJump(t *testing.T) {
	content := strings.Repeat("x\n", 100) // 200 bytes
	p := write(t, content)
	// 10-byte window, known offset 0: 200 > 10*4 behind → fresh window at the end.
	c, _ := Read(p, p, 0, 10, "tail")
	if c.Start != 190 || c.End != 200 {
		t.Fatalf("jump: %+v", c)
	}
}

func TestLongLineSkippedForward(t *testing.T) {
	// A 100-byte line then a short last line; window 20 opens inside the
	// long line, whose start is more than a window back → skip past it.
	content := strings.Repeat("L", 99) + "\n" + "short\n"
	p := write(t, content)
	c, _ := Read(p, "", 0, 20, "tail")
	if string(c.Bytes) != "short\n" {
		t.Fatalf("got %+v %q", c, c.Bytes)
	}
	// The long line is the last whole line: it must still show.
	content = "a\n" + strings.Repeat("L", 99) + "\n"
	p = write(t, content)
	c, _ = Read(p, "", 0, 20, "tail")
	if c.Start != 2 || c.End != int64(len(content)) {
		t.Fatalf("last long line: %+v", c)
	}
}

func TestEarlier(t *testing.T) {
	content := "one\ntwo\nthree\nfour\n"
	p := write(t, content)
	// The 6 bytes before offset 14 ("three\n" starts at 8): s0 = 8 → next
	// line after 8 is 14 (not < end) → line start of 13 = 8.
	c, _ := Read(p, p, 14, 6, "earlier")
	if c.Start != 8 || c.End != 14 || string(c.Bytes) != "three\n" {
		t.Fatalf("got %+v %q", c, c.Bytes)
	}
	// "from" is the plan's name for the same mode.
	c2, _ := Read(p, p, 14, 6, "from")
	if c2.Start != c.Start || c2.End != c.End || string(c2.Bytes) != string(c.Bytes) {
		t.Fatalf("from differs: %+v", c2)
	}
	// Everything before.
	c, _ = Read(p, p, 8, 1000, "earlier")
	if c.Start != 0 || c.End != 8 {
		t.Fatalf("all before: %+v", c)
	}
}

func TestFormatSanitizes(t *testing.T) {
	out := Format("/home/ubuntu/.claude/projects/x/a.jsonl", "", Chunk{Size: 3, Start: 0, End: 3, Bytes: []byte{'a', 0xff, '\n'}}, true)
	want := "/home/ubuntu/.claude/projects/x/a.jsonl\n\n3\n0\n3\na\n"
	if string(out) != want {
		t.Fatalf("got %q", out)
	}
	if string(Format("/p", "{}", Chunk{}, false)) != "/p\n{}\n" {
		t.Fatal("missing file format")
	}
}

func TestEncodings(t *testing.T) {
	if got := ClaudeDir(`C:\Users\you\src\my.proj`); got != "C--Users-you-src-my-proj" {
		t.Error(got)
	}
	if got := GrokEncode("/home/x y"); got != "%2Fhome%2Fx%20y" {
		t.Error(got)
	}
	if got := KimiSlug("请用中文回答-1004-2143"); got != "1004-2143" {
		t.Error(got)
	}
	if got := KimiSlug("café"); got != "caf" {
		t.Error(got)
	}
	if !strings.HasPrefix(KimiKey(`C:\src\proj\`), "wd_proj_") {
		t.Error(KimiKey(`C:\src\proj\`))
	}
}
