package vpath

import (
	"errors"
	"testing"
)

var win = &Mapper{Home: `C:\Users\you`, Temp: `C:\Users\you\AppData\Local\Temp`, Windows: true}
var mac = &Mapper{Home: "/Users/you", Temp: "/tmp", Windows: false}

func TestToVirtualWindows(t *testing.T) {
	cases := map[string]string{
		`C:\Users\you`:                      "/home/ubuntu",
		`C:\Users\you\`:                     "/home/ubuntu",
		`c:\users\YOU\src\x`:                "/home/ubuntu/src/x",
		`C:/Users/you/src/my proj`:          "/home/ubuntu/src/my proj",
		`\\?\C:\Users\you\long`:             "/home/ubuntu/long",
		`D:\src\proj`:                       "/d/src/proj",
		`D:\`:                               "/d",
		`d:`:                                "/d",
		`E:\données\été`:                    "/e/données/été",
		`C:\Users\you2\x`:                   "/c/Users/you2/x",
		`C:\Users\you\AppData\Local\Temp\a`: "/home/ubuntu/AppData/Local/Temp/a", // home wins over temp
		`C:\Users\you\\double\\sep`:         "/home/ubuntu/double/sep",
	}
	for in, want := range cases {
		got, err := win.ToVirtual(in)
		if err != nil || got != want {
			t.Errorf("ToVirtual(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	other := &Mapper{Home: `C:\Users\you`, Temp: `D:\tmp`, Windows: true}
	if got, _ := other.ToVirtual(`D:\tmp\x`); got != "/tmp/x" {
		t.Errorf("temp: %q", got)
	}
	for _, unc := range []string{`\\server\share\x`, `//server/share`, `\\?\UNC\server\share`} {
		if _, err := win.ToVirtual(unc); !errors.Is(err, ErrUNC) {
			t.Errorf("ToVirtual(%q) should refuse UNC, got %v", unc, err)
		}
	}
}

func TestToRealWindows(t *testing.T) {
	cases := map[string]string{
		"":                        `C:\Users\you`,
		"~":                       `C:\Users\you`,
		"~/src":                   `C:\Users\you\src`,
		"/home/ubuntu":            `C:\Users\you`,
		"/home/ubuntu/":           `C:\Users\you`,
		"/home/ubuntu/a b/c":      `C:\Users\you\a b\c`,
		"/home/ubuntu/.bromure/x": `C:\Users\you\.bromure\x`,
		"/d/src/proj":             `D:\src\proj`,
		"/d":                      `D:\`,
		"/c/Users/you/x":          `C:\Users\you\x`,
		"/tmp/bromure-msg-1.b64":  `C:\Users\you\AppData\Local\Temp\bromure-msg-1.b64`,
		"src/x":                   `C:\Users\you\src\x`,
		`D:\already\real`:         `D:\already\real`,
		"/e/日本語/フォルダ":             `E:\日本語\フォルダ`,
	}
	for in, want := range cases {
		got, err := win.ToReal(in)
		if err != nil || got != want {
			t.Errorf("ToReal(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	for _, bad := range []string{"/usr/bin", "/home/ubuntu2/x", "/proc/1"} {
		if _, err := win.ToReal(bad); err == nil {
			t.Errorf("ToReal(%q) should fail", bad)
		}
	}
	if _, err := win.ToReal(`\\server\share`); !errors.Is(err, ErrUNC) {
		t.Errorf("UNC: %v", err)
	}
}

func TestRoundTrip(t *testing.T) {
	for _, v := range []string{"/home/ubuntu", "/home/ubuntu/src/my proj", "/d/x/y", "/home/ubuntu/é/ü"} {
		r, err := win.ToReal(v)
		if err != nil {
			t.Fatal(err)
		}
		back, err := win.ToVirtual(r)
		if err != nil || back != v {
			t.Errorf("round trip %q → %q → %q (%v)", v, r, back, err)
		}
	}
}

func TestUnix(t *testing.T) {
	if v, _ := mac.ToVirtual("/Users/you/src"); v != "/home/ubuntu/src" {
		t.Error(v)
	}
	if v, _ := mac.ToVirtual("/Users/youth"); v != "/Users/youth" {
		t.Error(v)
	}
	if r, _ := mac.ToReal("/home/ubuntu/x"); r != "/Users/you/x" {
		t.Error(r)
	}
	if r, _ := mac.ToReal("/opt/x"); r != "/opt/x" {
		t.Error(r)
	}
	if s := mac.MapForBash("cat /home/ubuntu/.bromure/x"); s != "cat /Users/you/.bromure/x" {
		t.Error(s)
	}
}

func TestText(t *testing.T) {
	if s := win.MapForBash(`cat '/home/ubuntu/.bromure/transcript-1.path'`); s != `cat '/c/Users/you/.bromure/transcript-1.path'` {
		t.Error(s)
	}
	got := win.MapTextToReal("look at /home/ubuntu/.bromure/drops/1_0_a.png and \"/home/ubuntu/x/y\".")
	want := `look at C:\Users\you\.bromure\drops\1_0_a.png and "C:\Users\you\x\y".`
	if got != want {
		t.Errorf("MapTextToReal:\n got %q\nwant %q", got, want)
	}
	if s := win.MapTextToReal("/home/ubuntu2/x"); s != "/home/ubuntu2/x" {
		t.Error(s)
	}
	if s := win.MapTextToVirtual(`cwd C:\Users\you\src\x done`); s != "cwd /home/ubuntu/src/x done" {
		t.Error(s)
	}
	if s := win.MSYSHome(); s != "/c/Users/you" {
		t.Error(s)
	}
}

func TestCheckCwd(t *testing.T) {
	for _, ok := range []string{"/home/ubuntu/src/my proj", "/d/x-1_2.3+4", "/home/ubuntu/请用-1004", "/e/données"} {
		if CheckCwd(ok) != nil {
			t.Errorf("%q should pass", ok)
		}
	}
	for _, bad := range []string{"", "/home/ubuntu/a'b", "/home/ubuntu/a\nb", "/x/$HOME", "/x/a\u2028b", "/x/(1)"} {
		if CheckCwd(bad) == nil {
			t.Errorf("%q should fail", bad)
		}
	}
}

func TestMapOutput(t *testing.T) {
	in := "worktree C:/Users/you/.bromure/worktrees/x/y\n/c/Users/you/src\nC:\\Users\\you\\a b\nC:/Users/you2/z\n"
	want := "worktree /home/ubuntu/.bromure/worktrees/x/y\n/home/ubuntu/src\n/home/ubuntu/a b\nC:/Users/you2/z\n"
	if got := win.MapOutput(in); got != want {
		t.Errorf("MapOutput:\n got %q\nwant %q", got, want)
	}
	if got := mac.MapOutput("/Users/you/x /Users/youth"); got != "/home/ubuntu/x /Users/youth" {
		t.Error(got)
	}
}
