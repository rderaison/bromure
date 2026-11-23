package sessions

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestAgentTool(t *testing.T) {
	cases := map[string]string{
		`C:\Users\you\.local\bin\claude.exe --settings x`:                                                                                  "claude",
		`"C:\Program Files\nodejs\node.exe" C:\Users\you\AppData\Roaming\npm\node_modules\@openai\codex\bin\codex.js -c x`:                 "codex",
		`C:\Users\you\AppData\Roaming\npm\node_modules\@openai\codex\vendor\x86_64-pc-windows-msvc\codex\codex-x86_64-pc-windows-msvc.exe`: "codex",
		`/Users/you/.local/share/claude/versions/2.1.3 --resume x`:                                                                         "claude",
		`node /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js`:                                                                      "claude",
		`bun /home/x/.bun/bin/omp`: "omp",
		`kimi --yolo`:              "kimi",
		`C:\Program Files\Git\usr\bin\bash.exe --login -i`: "",
		`node server.js`: "",
		`grep claude`:    "",
	}
	for in, want := range cases {
		if got := AgentTool(in); got != want {
			t.Errorf("AgentTool(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestTimeAndUUIDWire(t *testing.T) {
	s := Session{ID: NewUUID(), ProfileID: NewUUID(), Tool: "claude", Title: "t", Cwd: "/home/ubuntu",
		CreatedAt: Time{time.Date(2026, 10, 24, 12, 0, 0, 123456789, time.UTC)}}
	data, _ := json.Marshal(s)
	js := string(data)
	if !strings.Contains(js, `"createdAt":"2026-10-24T12:00:00Z"`) {
		t.Errorf("date: %s", js)
	}
	if strings.Contains(js, "windowIndex") || strings.Contains(js, "endedAt") {
		t.Errorf("nil optionals must be omitted: %s", js)
	}
	if s.ID != strings.ToUpper(s.ID) || ParseUUID(strings.ToLower(s.ID)) != s.ID {
		t.Errorf("uuid case: %s", s.ID)
	}
	var back Session
	if err := json.Unmarshal(data, &back); err != nil || !back.CreatedAt.Equal(s.CreatedAt.Truncate(time.Second)) {
		t.Errorf("round trip: %v %v", err, back.CreatedAt)
	}
}

func TestTitles(t *testing.T) {
	if DefaultTitle("claude", "/home/ubuntu/src/app") != "Claude in app" {
		t.Error(DefaultTitle("claude", "/home/ubuntu/src/app"))
	}
	long := strings.Repeat("x", 80)
	if got := Title(long+"\nmore", "claude", "/x"); len([]rune(got)) != 58 || !strings.HasSuffix(got, "…") {
		t.Error(got)
	}
}

func TestMenuOpen(t *testing.T) {
	if !MenuOpen("foo\n❯ 1. Yes\n  2. No\nEnter to confirm · Esc to cancel") {
		t.Error("picker")
	}
	if MenuOpen("> hello world\n1. a list item") {
		t.Error("plain text")
	}
}

func TestCompletionSafe(t *testing.T) {
	if CompletionSafe("run ls /tmp") != "run ls /tmp " {
		t.Error("path")
	}
	if CompletionSafe("/model") != "/model" {
		t.Error("single slash command keeps its popup")
	}
	if CompletionSafe("hello there") != "hello there" {
		t.Error("plain")
	}
}

func TestReviewMessage(t *testing.T) {
	f, l := "a.go", 3
	m := ReviewMessage([]ReviewComment{{Text: "fix", File: &f, Line: &l}, {Text: "also"}})
	want := "Review comments on your changes — address each one, then reply briefly with what you changed:\n\n1. `a.go` line 3: fix\n2. also"
	if m != want {
		t.Errorf("got %q", m)
	}
}

func TestParsePaneTarget(t *testing.T) {
	raw := map[string]any{}
	_ = json.Unmarshal([]byte(`{"ref":{"windowID":{"_0":"@3"}},"expectWindowID":"@3","expectDisplay":"Fix bug","foreground":{"agent":{}}}`), &raw)
	tg, ok := ParsePaneTarget(raw)
	if !ok || tg.ExpectWindowID == nil || *tg.ExpectWindowID != "@3" || tg.wantsShell() {
		t.Fatalf("%+v %v", tg, ok)
	}
}

func TestNaturalLess(t *testing.T) {
	if !naturalLess("file2", "file10") || naturalLess("B", "a") {
		t.Error("natural order")
	}
}
