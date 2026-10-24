package shims

import (
	"bytes"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/rderaison/bromure/sidecar/internal/vpath"
)

// The client's reader heredoc (CodingTasks.transcriptReaderPython), as much
// of it as recognition looks at.
const readerScript = `import sys, os
f, known, off, want, mode = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
def line_start(fh, pos, limit):
    pass
def whole_end(fh, start, end):
    pass
    sys.stdout.write('%d\n%d\n%d\n' % (size, start, end))
`

func TestPythonShimAnswersTheTranscriptReader(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "t.jsonl")
	os.WriteFile(p, []byte("{\"a\":1}\n{\"b\":2}\npartial"), 0o644)
	// This OS's own mapper, home = the temp dir: the client names the file
	// as bash here writes it (/c/…/t.jsonl on Windows).
	saved := vpath.Default()
	m := &vpath.Mapper{Home: dir, Temp: os.TempDir(), Windows: runtime.GOOS == "windows"}
	vpath.SetDefaultForTest(m)
	defer vpath.SetDefaultForTest(saved)
	bashForm := m.MapForBash(vpath.GuestHome + "/t.jsonl")
	var out, errb bytes.Buffer
	code := RunPython([]string{"-", bashForm, "", "0", "1000", "tail"}, strings.NewReader(readerScript), &out, &errb)
	if code != 0 {
		t.Fatalf("exit %d: %s", code, errb.String())
	}
	want := "23\n0\n16\n{\"a\":1}\n{\"b\":2}\n"
	if out.String() != want {
		t.Fatalf("got %q want %q", out.String(), want)
	}
	// The known path differs only in form (what the client echoes back is
	// the mapped path): still an incremental read from the offset.
	out.Reset()
	RunPython([]string{"-", bashForm, vpath.GuestHome + "/t.jsonl", "8", "1000", "tail"}, strings.NewReader(readerScript), &out, &errb)
	if !strings.HasPrefix(out.String(), "23\n8\n16\n") {
		t.Fatalf("incremental: %q", out.String())
	}
}

func TestPythonShimGrokQuote(t *testing.T) {
	var out, errb bytes.Buffer
	RunPython([]string{"-c", `import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))`, "/home/x y"}, nil, &out, &errb)
	if out.String() != "%2Fhome%2Fx%20y\n" {
		t.Fatalf("%q", out.String())
	}
}
