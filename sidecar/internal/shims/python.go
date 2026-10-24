package shims

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/rderaison/bromure/sidecar/internal/paths"
	"github.com/rderaison/bromure/sidecar/internal/transcripts"
	"github.com/rderaison/bromure/sidecar/internal/vpath"
)

// RunPython is the `python3` shim (bin/python3[.exe]). Bromure AC runs two
// small Python programs on a native machine as it does in a Linux guest,
// and neither works with a Windows Python (it can't open Git Bash's
// /c/… paths, and it prints CRLF): the beautified view's transcript reader
// (CodingTasks.transcriptReaderPython, `python3 - f known off bytes mode`)
// and Grok's cwd percent-encoding. Both are answered here, in Go; anything
// else goes to a real Python further down the PATH.
func RunPython(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) >= 6 && args[0] == "-" {
		script, _ := io.ReadAll(io.LimitReader(stdin, 1<<20))
		if isTranscriptReader(script) {
			return transcriptReader(args[1:6], stdout)
		}
		return realPython(args, bytes.NewReader(script), stdout, stderr)
	}
	if len(args) == 3 && args[0] == "-c" && strings.Contains(args[1], "urllib.parse.quote(sys.argv[1],safe=") {
		fmt.Fprintln(stdout, transcripts.GrokEncode(args[2]))
		return 0
	}
	return realPython(args, stdin, stdout, stderr)
}

// isTranscriptReader recognises the client's reader by its own functions.
func isTranscriptReader(script []byte) bool {
	return bytes.Contains(script, []byte("def line_start(")) &&
		bytes.Contains(script, []byte("def whole_end(")) &&
		bytes.Contains(script, []byte("sys.stdout.write('%d\\n%d\\n%d\\n'"))
}

// transcriptReader is the reader's argv: file, known path, offset, window,
// mode. Prints `size\nstart\nend\n` then the bytes, LF only.
func transcriptReader(a []string, stdout io.Writer) int {
	m := vpath.Default()
	toReal := func(p string) string {
		if p == "" {
			return ""
		}
		if r, err := m.ToReal(p); err == nil {
			return r
		}
		return p
	}
	f, known := toReal(a[0]), toReal(a[1])
	off, err1 := strconv.ParseInt(a[2], 10, 64)
	want, err2 := strconv.ParseInt(a[3], 10, 64)
	if err1 != nil || err2 != nil {
		return 1
	}
	c, ok := transcripts.Read(f, known, off, want, a[4])
	if !ok {
		return 0 // the python exits 0 with nothing when the file is gone
	}
	fmt.Fprintf(stdout, "%d\n%d\n%d\n", c.Size, c.Start, c.End)
	stdout.Write(c.Bytes)
	return 0
}

// realPython runs the first python3/python on the PATH that isn't this
// shim (nor the Microsoft Store's install stub).
func realPython(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	self := strings.ToLower(filepath.Clean(paths.BinDir()))
	for _, dir := range filepath.SplitList(os.Getenv("PATH")) {
		if strings.ToLower(filepath.Clean(dir)) == self {
			continue
		}
		for _, name := range []string{"python3", "python"} {
			p := filepath.Join(dir, paths.ExeName(name))
			st, err := os.Stat(p)
			if err != nil || st.IsDir() {
				continue
			}
			cmd := exec.Command(p, args...)
			cmd.Stdin, cmd.Stdout, cmd.Stderr = stdin, stdout, stderr
			if err := cmd.Run(); err != nil {
				if ee, ok := err.(*exec.ExitError); ok {
					return ee.ExitCode()
				}
				return 127
			}
			return 0
		}
	}
	fmt.Fprintln(stderr, "python3: not found (Bromure Sidecar answers only the transcript reader itself)")
	return 127
}
