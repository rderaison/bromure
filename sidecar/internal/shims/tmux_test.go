package shims

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/rderaison/bromure/sidecar/internal/paths"
)

// Expected outputs below were taken from a real tmux 3.4 (Ubuntu 24.04)
// given the same state, unless noted.

func run(t *testing.T, f *fakeClient, args ...string) (string, string, int) {
	t.Helper()
	return tmuxOut(f, nil, "", args...)
}

func want(t *testing.T, got, w string) {
	t.Helper()
	if got != w {
		t.Fatalf("got %q, want %q", got, w)
	}
}

func TestDisplayFormats(t *testing.T) {
	f := standardFake(t)
	out, _, st := run(t, f, "display-message", "-p", "-t", "bromure:1",
		"#{window_index} #{window_id} #{pane_id} #{pane_tty} #{pane_pid} #{pane_current_path} #{pane_current_command} #{window_width} #{window_height} #{pane_height}")
	want(t, out, "1 @1 %1 /dev/pty/bromure-1 200 /home/ubuntu/src/proj claude 120 40 40\n")
	if st != 0 {
		t.Fatal(st)
	}
	out, _, _ = run(t, f, "display-message", "-p", "-t", "bromure:1", "#{cursor_flag} #{cursor_x} #{cursor_y} #{pane_height}")
	want(t, out, "1 4 37 40\n")
	out, _, _ = run(t, f, "display-message", "-p", "-t", "bromure:1",
		"#{@worktree}|#{@display}|#{@unset}|#{window_name}|#{window_active}|#{session_name}|#{pane_index}|#{pane_in_mode}|#{alternate_on}|#{pane_dead}|#{pane_title}")
	want(t, out, "wt/fix-bug|Fix the bug||claude|0|bromure|0|0|0|0|✳ Fix the bug\n")
	// tmux's own aliases and escapes
	out, _, _ = run(t, f, "display-message", "-p", "-t", "bromure:1", "#I #W #S #D #P ## #, #Q w#{window_index}")
	want(t, out, "1 claude bromure %1 0 # , #Q w1\n")
}

func TestFormatConditionals(t *testing.T) {
	f := standardFake(t)
	cases := map[string]string{
		"#{?window_active,yes,no}":                                 "no",
		"#{?#{==:#{window_index},1},one,other}":                    "one",
		"#{==:a,a} #{!=:a,b} #{||:0,1} #{&&:1,0}":                  "1 1 1 0",
		"#{?#{==:1,2},a,#{==:1,1},b,c}":                            "1,b,c", // no else-if chains in 3.4
		"#{?nosuch,y,n}":                                           "n",
		"#{=3:window_name}|#{=-2:window_name}":                     "cla|de",
		"#{=/2/..:window_name}":                                    "cl..",
		"#{b:pane_current_path} #{d:pane_current_path}":            "proj /home/ubuntu/src",
		"#{e|+:1,2} #{e|*:3,4} #{e|/|f:7,2}":                       "3 12 3.50",
		"#{m:*lau*,claude} #{s/a/A/:window_name} #{n:window_name}": "1 clAude 6",
		"#{l:#{window_index}}":                                     "#{window_index}",
		"x#(echo hi)y #[fg=red]z":                                  "xy #[fg=red]z",
		"#{?@worktree,tagged,plain}":                               "tagged",
		"#{W:#{window_index} }":                                    "0 1 3 ",
	}
	for in, w := range cases {
		out, _, _ := run(t, f, "display-message", "-p", "-t", "bromure:1", in)
		if out != w+"\n" {
			t.Errorf("%s → %q, want %q", in, out, w)
		}
	}
	// A broken conditional ends the expansion, as in tmux.
	out, _, _ := run(t, f, "display-message", "-p", "-t", "bromure:1", "a|#{?window_id,y}|b")
	want(t, out, "a|\n")
	out, _, _ = run(t, f, "display-message", "-p", "-t", "bromure:1", "#{window_index}|#{window_index")
	want(t, out, "1|\n")
}

func TestOutputEscaping(t *testing.T) {
	f := standardFake(t)
	f.wins[1].Options["@worktree"] = "a\tb\x1fc\x1bd\re\\f é\a\b\v\f\x01\x7fZ"
	out, _, _ := run(t, f, "list-windows", "-t", "bromure", "-F", "#{window_index}\t#{@worktree}")
	want(t, out, "0\t\n1\ta\tb\\037c\\033d\\re\\f é\\a\\b\\v\\f\\001\\177Z\n3\twt/other\n")
	// a literal \037 in the format (the client's $'\037' separator)
	out, _, _ = run(t, f, "display-message", "-p", "-t", "bromure:1", "x\x1fy")
	want(t, out, "x\\037y\n")
	// invalid UTF-8 → octal
	f.wins[1].Options["@worktree"] = "bad\xff\xc3(x"
	out, _, _ = run(t, f, "display-message", "-p", "-t", "bromure:1", "#{@worktree}")
	want(t, out, "bad\\377\\303(x\n")
	// a client that isn't UTF-8 (LANG=C, no -u): '_' for non-ASCII, TAB too
	f.wins[1].Options["@worktree"] = "é\tx"
	o2, _, _ := tmuxOut(f, map[string]string{"LANG": "C"}, "", "display-message", "-p", "-t", "bromure:1", "#{@worktree}")
	want(t, o2, "__x\n")
	o3, _, _ := tmuxOut(f, map[string]string{"LANG": "C"}, "", "-u", "display-message", "-p", "-t", "bromure:1", "#{@worktree}")
	want(t, o3, "é\tx\n")
}

func TestTargets(t *testing.T) {
	f := standardFake(t)
	for tgt, w := range map[string]string{
		"bromure:1": "@1", "@3": "@3", "%3": "@3", ":1": "@1", "1": "@1", "bromure": "@0", "": "@0",
		"bromure:claude": "@1", "bromure:cod": "@3", "=bromure:1": "@1", "bromure:$": "@3", "bromure:^": "@0",
		"bromure:1.0": "@1", "view-mac-1": "@0",
	} {
		args := []string{"display-message", "-p"}
		if tgt != "" {
			args = append(args, "-t", tgt)
		}
		out, errs, st := run(t, f, append(args, "#{window_id}")...)
		if out != w+"\n" || st != 0 || errs != "" {
			t.Errorf("-t %q → %q %q %d, want %s", tgt, out, errs, st, w)
		}
	}
	// display-message is CANFAIL: a missing window falls back to the
	// session's current one; a missing id gives an empty context. (tmux 3.4.)
	out, errs, st := run(t, f, "display-message", "-p", "-t", "bromure:7", "#{window_id} #{session_name}")
	want(t, out+errs, "@0 bromure\n")
	if st != 0 {
		t.Fatal(st)
	}
	out, _, st = run(t, f, "display-message", "-p", "-t", "@99", "#{window_id}|#{session_name}|#{pane_tty}")
	want(t, out, "||\n")
	// Strict commands: tmux's messages.
	for _, c := range []struct {
		args []string
		msg  string
	}{
		{[]string{"capture-pane", "-p", "-t", "bromure:9"}, "can't find window: 9\n"},
		{[]string{"capture-pane", "-p", "-t", "nosuch"}, "can't find pane: nosuch\n"},
		{[]string{"send-keys", "-t", "@99", "Enter"}, "can't find window: @99\n"},
		{[]string{"kill-window", "-t", "%99"}, "can't find pane: %99\n"},
		{[]string{"kill-window", "-t", "nosuch"}, "can't find window: nosuch\n"},
		{[]string{"list-windows", "-t", "nosuch"}, "can't find session: nosuch\n"},
		{[]string{"has-session", "-t", "nosuch"}, "can't find session: nosuch\n"},
		{[]string{"has-session", "-t", "bromure:7"}, "can't find window: 7\n"},
		{[]string{"resize-window", "-t", "bromure:9", "-x", "10", "-y", "10"}, "can't find window: 9\n"},
		{[]string{"select-window", "-t", "bromure:9"}, "can't find window: 9\n"},
		{[]string{"show-options", "-w", "-v", "-t", "bromure:7", "@worktree"}, "no such window: bromure:7\n"},
		{[]string{"set-option", "-w", "-t", "@99", "@a", "1"}, "no such window: @99\n"},
		{[]string{"refresh-client", "-t", "/dev/pts/99", "-f", "ignore-size"}, "can't find client: /dev/pts/99\n"},
	} {
		out, errs, st := run(t, f, c.args...)
		if st != 1 || errs != c.msg || out != "" {
			t.Errorf("%v → %q %q %d, want %q", c.args, out, errs, st, c.msg)
		}
	}
	// -q silences a bad show-options target
	if out, errs, st := run(t, f, "show-options", "-wqv", "-t", "bromure:7", "@worktree"); out+errs != "" || st != 0 {
		t.Errorf("show -q: %q %q %d", out, errs, st)
	}
	// Inside a window, no -t means that window (TMUX_PANE / BROMURE_WINDOW).
	out, _, _ = tmuxOut(f, map[string]string{"TMUX_PANE": "%3"}, "", "display-message", "-p", "#{window_index}")
	want(t, out, "3\n")
	out, _, _ = tmuxOut(f, map[string]string{"BROMURE_WINDOW": "1"}, "", "display-message", "-p", "#{window_index}")
	want(t, out, "1\n")
}

func TestHasSessionAndServer(t *testing.T) {
	f := standardFake(t)
	for _, s := range []string{"bromure", "view-abc", ""} {
		args := []string{"has-session"}
		if s != "" {
			args = append(args, "-t", s)
		}
		if _, _, st := run(t, f, args...); st != 0 {
			t.Errorf("has-session %q: %d", s, st)
		}
	}
	_, errs, st := tmuxOut(nil, nil, "", "has-session", "-t", "bromure")
	if st != 1 || errs != "no server running on /tmp/tmux-1000/default\n" {
		t.Fatalf("no pane host: %q %d", errs, st)
	}
	_, errs, _ = tmuxOut(nil, nil, "", "-L", "probe", "list-windows")
	want(t, errs, "no server running on /tmp/tmux-1000/probe\n")
	out, _, st := run(t, f, "-V")
	if out != "tmux 3.4\n" || st != 0 {
		t.Fatal(out)
	}
}

func TestParseErrors(t *testing.T) {
	f := standardFake(t)
	for _, c := range []struct {
		args []string
		msg  string
	}{
		{[]string{"frobnicate"}, "unknown command: frobnicate\n"},
		{[]string{"list-windows", "-Z"}, "command list-windows: unknown flag -Z\n"},
		{[]string{"list-windows", "-t", "bromure", "extra"}, "command list-windows: too many arguments (need at most 0)\n"},
		{[]string{"display-message", "-p", "-t", "bromure:1", "-F"}, "command display-message: -F expects an argument\n"},
		{[]string{"display-message", "-p", "a", "b"}, "command display-message: too many arguments (need at most 1)\n"},
		{[]string{"list", "-t", "bromure"}, "ambiguous command: list, could be: list-buffers, list-clients, list-commands, list-keys, list-panes, list-sessions, list-windows\n"},
		{[]string{"set-option", "-w", "-t", "bromure:1", "@k"}, "empty value\n"},
		{[]string{"swap-window", "-s", "1", "-t", "2"}, "unknown command: swap-window\n"},
		{[]string{"resize-window", "-t", "bromure:1", "-x", "abc"}, "width invalid\n"},
	} {
		_, errs, st := run(t, f, c.args...)
		if st != 1 || errs != c.msg {
			t.Errorf("%v → %q %d, want %q", c.args, errs, st, c.msg)
		}
	}
	// a parse error anywhere means nothing runs
	run(t, f, "select-window", "-t", "bromure:3", ";", "list-windows", "-Z")
	if len(f.selected) != 0 {
		t.Fatal("ran a command before a parse error")
	}
	// the unknown command was logged once, by marker file
	if _, err := os.Stat(filepath.Join(paths.LogsDir(), "shim-gaps", "tmux-swap-window")); err != nil {
		t.Fatalf("no gap marker: %v", err)
	}
	// aliases resolve
	out, _, _ := run(t, f, "display", "-p", "-t", "bromure:1", "#{window_index}")
	want(t, out, "1\n")
}

func TestSequences(t *testing.T) {
	f := standardFake(t)
	// The Swift Sidecar's hook: set-option … ; set-option …
	_, errs, st := run(t, f, "set-option", "-w", "-t", "%1", "@bromure_status", "working", ";",
		"set-option", "-w", "-t", "%1", "@bromure_transcript", "/home/ubuntu/t.jsonl")
	if st != 0 || errs != "" || f.wins[1].Options["@bromure_status"] != "working" || f.wins[1].Options["@bromure_transcript"] == "" {
		t.Fatalf("%q %d %v", errs, st, f.wins[1].Options)
	}
	// "x;" ends a command; "x\;" is a literal ;
	out, _, _ := run(t, f, "set-option", "-w", "-t", "bromure:1", "@a", "1;", "show-options", "-wv", "-t", "bromure:1", "@a")
	want(t, out, "1\n")
	out, _, _ = run(t, f, "set-option", "-w", "-t", "bromure:1", "@a", `x\;`, ";", "show-options", "-wv", "-t", "bromure:1", "@a")
	want(t, out, "x;\n")
	// an error stops the rest
	out, errs, st = run(t, f, "select-window", "-t", "bromure:1", ";", "select-window", "-t", "bromure:99", ";", "display-message", "-p", "never")
	if out != "" || errs != "can't find window: 99\n" || st != 1 {
		t.Fatalf("%q %q %d", out, errs, st)
	}
}

func TestOptions(t *testing.T) {
	f := standardFake(t)
	out, _, _ := run(t, f, "show-options", "-w", "-v", "-t", "bromure:1", "@worktree")
	want(t, out, "wt/fix-bug\n")
	out, _, _ = run(t, f, "show-options", "-w", "-t", "bromure:1", "@display")
	want(t, out, "@display \"Fix the bug\"\n")
	_, errs, st := run(t, f, "show-options", "-w", "-v", "-t", "bromure:1", "@nope")
	if errs != "invalid option: @nope\n" || st != 1 {
		t.Fatal(errs)
	}
	for v, w := range map[string]string{`a"b`: `'a"b'`, `a\b`: `a\\b`, `a$b`: `"a\\$b"`, "a b": `"a b"`, "~x": `\~x`,
		"#": `\#`, "x": "x", " ": `" "`, "a\tb": `a\tb`, "a\nb": `a\nb`, "~a b": `"\~a b"`, "a,b": "a,b", "": "''"} {
		f.wins[1].Options["@q"] = v
		out, _, _ := run(t, f, "show-options", "-w", "-t", "bromure:1", "@q")
		if out != "@q "+w+"\n" {
			t.Errorf("%q → %q, want %q", v, out, "@q "+w)
		}
	}
	// -a appends, -o refuses an existing one, -u unsets
	run(t, f, "set-option", "-w", "-a", "-t", "bromure:1", "@r", "x", ";", "set-option", "-w", "-a", "-t", "bromure:1", "@r", "y")
	want(t, f.wins[1].Options["@r"], "xy")
	_, errs, _ = run(t, f, "set-option", "-w", "-o", "-t", "bromure:1", "@worktree", "z")
	want(t, errs, "already set: @worktree\n")
	run(t, f, "set-option", "-wu", "-t", "bromure:1", "@r")
	if _, ok := f.wins[1].Options["@r"]; ok {
		t.Fatal("not unset")
	}
	// tmux options are accepted and change nothing here
	for _, args := range [][]string{{"set-option", "-wu", "-t", "bromure:0", "window-size"}, {"set-option", "-t", "bromure", "mouse", "off"},
		{"set-option", "status", "off"}, {"set-option", "-s", "set-clipboard", "on"}} {
		if _, errs, st := run(t, f, args...); st != 0 || errs != "" {
			t.Errorf("%v: %q", args, errs)
		}
	}
	// session and global @options: visible to formats, not to show -w
	run(t, f, "set-option", "-t", "bromure:1", "@sess", "S")
	_, errs, _ = run(t, f, "show-options", "-w", "-v", "-t", "bromure:1", "@sess")
	want(t, errs, "invalid option: @sess\n")
	out, _, _ = run(t, f, "display-message", "-p", "-t", "bromure:3", "#{@sess}")
	want(t, out, "S\n")
	run(t, f, "set-option", "-g", "@g", "1")
	out, _, _ = run(t, f, "show-options", "-g", "@g")
	want(t, out, "@g 1\n")
}

func TestCaptureFlags(t *testing.T) {
	f := standardFake(t)
	out, _, _ := run(t, f, "capture-pane", "-p", "-t", "bromure:1")
	want(t, out, "line one\n> draft\n")
	f.captured = nil
	run(t, f, "capture-pane", "-p", "-J", "-S", "-300", "-t", "bromure:1")
	run(t, f, "capture-pane", "-p", "-J", "-S", "-", "-t", "bromure:1")
	run(t, f, "capture-pane", "-p", "-e", "-t", "bromure:1", "-S", "-120", "-E", "-")
	run(t, f, "capture-pane", "-p", "-t", "bromure:1", "-S", "-5", "-E", "2")
	c := f.captured
	if len(c) != 4 || !c[0].Join || c[0].Start == nil || *c[0].Start != -300 || !c[1].StartHistory ||
		!c[2].Escapes || !c[2].EndVisible || *c[2].Start != -120 || *c[3].End != 2 || c[3].Join {
		t.Fatalf("%+v", c)
	}
	// a capture without a trailing newline gets one
	f.captures[1] = "x"
	out, _, _ = run(t, f, "capture-pane", "-p", "-t", "bromure:1")
	want(t, out, "x\n")
	// without -p: into a buffer
	run(t, f, "capture-pane", "-t", "bromure:1", "-b", "cap")
	want(t, string(f.buffers["cap"]), "x")
}

func TestSendKeys(t *testing.T) {
	f := standardFake(t)
	run(t, f, "send-keys", "-t", "@1", "C-c")
	run(t, f, "send-keys", "-t", "bromure:1", "-l", "--", "hello world")
	run(t, f, "send-keys", "-t", "bromure:1", "-l", "3")
	run(t, f, "send-keys", "-t", "bromure:1", "Escape", "y", "Enter", "some text", "Up", "C-M-x", "BSpace")
	run(t, f, "send-keys", "-t", "bromure:1", "-H", "41", "42")
	run(t, f, "send-keys", "-t", "bromure:1", "-N", "2", "Tab")
	w := []string{
		"1:keys:C-c", "1:literal:hello world", "1:literal:3",
		"1:keys:Escape,y,Enter", "1:literal:some text", "1:keys:Up,C-M-x,BSpace",
		"1:literal:AB", "1:keys:Tab", "1:keys:Tab",
	}
	want(t, strings.Join(f.keys, "|"), strings.Join(w, "|"))
	_, errs, st := run(t, f, "send-keys", "-t", "bromure:1", "-X", "cancel")
	if errs != "not in a mode\n" || st != 1 {
		t.Fatal(errs)
	}
}

func TestBuffers(t *testing.T) {
	f := standardFake(t)
	// PaneTypeGuard.literalSend: load-buffer -b X - && paste-buffer -p -r -d -b X -t @1
	_, errs, st := tmuxOut(f, nil, "multi\nline message", "load-buffer", "-b", "bromure-msg-1", "-")
	if st != 0 || errs != "" {
		t.Fatal(errs)
	}
	_, errs, st = run(t, f, "paste-buffer", "-p", "-r", "-d", "-b", "bromure-msg-1", "-t", "@1")
	if st != 0 || errs != "" || len(f.pastes) != 1 || f.pastes[0] != "1:true:true:multi\nline message" {
		t.Fatalf("%q %v", errs, f.pastes)
	}
	if _, ok := f.buffers["bromure-msg-1"]; ok {
		t.Fatal("-d didn't delete")
	}
	_, errs, st = run(t, f, "paste-buffer", "-b", "nobuf", "-t", "bromure:1")
	if errs != "no buffer nobuf\n" || st != 1 {
		t.Fatal(errs)
	}
	_, errs, _ = run(t, f, "delete-buffer", "-b", "nobuf")
	want(t, errs, "unknown buffer: nobuf\n")
}

func TestListings(t *testing.T) {
	f := standardFake(t)
	out, _, _ := run(t, f, "list-windows", "-t", "bromure", "-F", "#{window_index} #{@worktree}")
	want(t, out, "0 \n1 wt/fix-bug\n3 wt/other\n")
	out, _, _ = run(t, f, "-u", "list-windows", "-t", "bromure", "-F", "#{@worktree}\t#{pane_current_path}")
	want(t, out, "\t/home/ubuntu\nwt/fix-bug\t/home/ubuntu/src/proj\nwt/other\t/home/ubuntu/src/other\n")
	// default formats (tmux 3.4's templates; layout checksum as tmux's)
	out, _, _ = run(t, f, "list-windows", "-t", "bromure")
	if !strings.HasPrefix(out, "0: shell* (1 panes) [120x40] [layout ") || !strings.Contains(out, "@0 (active)\n1: claude (1 panes)") {
		t.Fatalf("%q", out)
	}
	f2 := standardFake(t)
	f2.wins[0].PaneID = "%0"
	out, _, _ = run(t, f2, "display-message", "-p", "-t", "bromure:0", "#{window_layout}")
	want(t, out, "aafd,120x40,0,0,0\n") // tmux 3.4 for a 120x40 window, pane %0
	out, _, _ = run(t, f, "list-panes", "-s", "-t", "bromure", "-F", "#{window_index} #{window_id} #{pane_tty} #{pane_title}")
	host := (&tmuxRun{}).hostname()
	want(t, out, "0 @0 /dev/pty/bromure-0 "+host+"\n1 @1 /dev/pty/bromure-1 ✳ Fix the bug\n3 @3 /dev/pty/bromure-3 "+host+"\n")
	out, _, _ = run(t, f, "list-panes", "-t", "bromure:1", "-F", "#{pane_index}")
	want(t, out, "0\n")
	// clients: all, or a view session's
	out, _, _ = run(t, f, "list-clients", "-F", "#{window_index} #{client_flags}")
	want(t, out, "1 attached,focused,UTF-8\n3 attached,ignore-size,UTF-8\n")
	out, _, _ = run(t, f, "list-clients", "-t", "view-mac-3", "-F", "#{client_tty} #{client_width} #{client_height}")
	want(t, out, "/dev/pty/bromure-client-2 80 24\n")
	// hidden windows aren't listed but stay addressable
	f.wins[3].Hidden = true
	out, _, _ = run(t, f, "list-windows", "-F", "#{window_index}")
	want(t, out, "0\n1\n")
	out, _, _ = run(t, f, "display-message", "-p", "-t", "%3", "#{window_index}")
	want(t, out, "3\n")
}

func TestWindowCommands(t *testing.T) {
	f := standardFake(t)
	run(t, f, "select-window", "-t", "bromure:3")
	run(t, f, "resize-window", "-t", "bromure:1", "-x", "100", "-y", "30")
	run(t, f, "kill-window", "-t", "@3")
	if len(f.selected) != 1 || f.selected[0] != 3 || f.resized[0] != "1:100x30" || f.killed[0] != 3 {
		t.Fatalf("%v %v %v", f.selected, f.resized, f.killed)
	}
	// kill-session -t view-*: its clients detach; nothing else goes
	if _, errs, st := run(t, f, "kill-session", "-t", "view-mac-1"); st != 0 || errs != "" || len(f.killed) != 1 || f.detached[0] != "view-mac-1" {
		t.Fatalf("%q %v %v", errs, f.killed, f.detached)
	}
	// refresh-client: size authority goes to the pane host
	run(t, f, "refresh-client", "-t", "/dev/pty/bromure-client-1", "-f", "!ignore-size")
	run(t, f, "refresh-client", "-t", "/dev/pty/bromure-client-1", "-C", "120x40")
	run(t, f, "refresh-client", "-t", "c2", "-f", "ignore-size")
	want(t, strings.Join(f.refreshed, " "), "c1:false:0x0 c1:-:120x40 c2:true:0x0")
	_, errs, st := run(t, f, "refresh-client")
	if errs != "no current client\n" || st != 1 {
		t.Fatal(errs)
	}
	// new-window runs Git Bash (BROMURE_GIT_BASH) and prints -P
	out, _, st := tmuxOut(f, map[string]string{"BROMURE_GIT_BASH": `C:\Git\bin\bash.exe`, "LANG": "C.UTF-8"}, "",
		"new-window", "-d", "-P", "-F", "#{window_index} #{window_id}", "-t", "bromure:", "-n", "scratch", "-c", "/home/ubuntu/src")
	nw := f.wins[2] // the first free index in the fake
	if st != 0 || out != "2 @10\n" || nw == nil || nw.Name != "scratch" || nw.Cwd != "/home/me/src" {
		t.Fatalf("%q %d %+v", out, st, nw)
	}
	if len(f.selected) != 1 {
		t.Fatal("-d selected the new window")
	}
}

func TestKeyNames(t *testing.T) {
	for _, k := range []string{"Enter", "enter", "C-c", "M-x", "C-M-Up", "BSpace", "F12", "^C", "y", "3", "Escape", "PgUp", "KPEnter"} {
		if !IsKeyName(k) {
			t.Errorf("%s should be a key", k)
		}
	}
	for _, k := range []string{"hello", "Enterx", "C-", "two words"} {
		if IsKeyName(k) {
			t.Errorf("%s shouldn't be a key", k)
		}
	}
}

// The contract extractor finds a form the shim doesn't serve, with its
// file:line (what a client change would trip).
func TestExtractorFlagsNewForms(t *testing.T) {
	dir := t.TempDir()
	ac := filepath.Join(dir, "Sources", "AgentCoding")
	os.MkdirAll(ac, 0o755)
	src := "let a = \"tmux swap-window -s bromure:\\(w) -t bromure:2 2>/dev/null; true\"\n" +
		"// tmux kill-server  (a comment: ignored)\n" +
		"let help = \"Attach your terminal to a VM's tmux session, a tab\"\n" +
		"let b = \"\"\"\n    x=1\n    # tmux list-windows -Z  (a shell comment)\n    tmux display-message -p -t \"$_bt\" '#{window_id}' \\\n      && tmux capture-pane -p -Q\n    \"\"\"\n" +
		"let c = \"_bt=$(tmux list-windows -t bromure -F '#{window_id} #{@worktree}' 2>/dev/null \"\n    + \"| awk '$2==b'); ps -t \\\"$t\\\" -o pid=,bogus=\"\n"
	os.WriteFile(filepath.Join(ac, "X.swift"), []byte(src), 0o644)
	c := extract(t, ac)
	var got []string
	for _, inv := range c.tmux {
		if err := ParseTmux(inv.args); err != nil {
			got = append(got, inv.pos+" "+err.Error())
		}
	}
	for _, inv := range c.ps {
		if err := ParsePs(inv.args); err != nil {
			got = append(got, inv.pos+" "+strings.SplitN(err.Error(), "\n", 2)[0])
		}
	}
	w := "AgentCoding/X.swift:1 unknown command: swap-window|AgentCoding/X.swift:8 command capture-pane: unknown flag -Q|" +
		"AgentCoding/X.swift:10 error: unknown user-defined format specifier \"bogus\""
	want(t, strings.Join(got, "|"), w)
	if len(c.tmux) != 4 {
		t.Fatalf("extracted %d: %+v", len(c.tmux), c.tmux)
	}
}
