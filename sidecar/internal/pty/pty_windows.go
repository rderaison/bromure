//go:build windows

package pty

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf16"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Process is a program on a ConPTY, in its own Job object.
type Process struct {
	info
	hpc  windows.Handle
	job  windows.Handle
	proc windows.Handle

	rmu       sync.Mutex // serialises Read against closing outR
	outR      windows.Handle
	outClosed bool

	wmu      sync.Mutex
	inW      windows.Handle
	inClosed bool

	pmu      sync.Mutex // proc and job handles
	procOpen bool

	done     chan struct{}
	exitCode int

	closeOnce sync.Once
	closed    chan struct{}
}

// Start runs spec on a new pseudoconsole.
func Start(spec Spec) (*Process, error) {
	app, cmdline, err := commandLine(spec)
	if err != nil {
		return nil, err
	}
	cols, rows := spec.size()

	var inR, inW, outR, outW windows.Handle
	if err := windows.CreatePipe(&inR, &inW, nil, 0); err != nil {
		return nil, fmt.Errorf("pty: input pipe: %w", err)
	}
	if err := windows.CreatePipe(&outR, &outW, nil, 0); err != nil {
		windows.CloseHandle(inR)
		windows.CloseHandle(inW)
		return nil, fmt.Errorf("pty: output pipe: %w", err)
	}
	closeAll := func(hs ...windows.Handle) {
		for _, h := range hs {
			if h != 0 {
				windows.CloseHandle(h)
			}
		}
	}

	var hpc windows.Handle
	if err := windows.CreatePseudoConsole(windows.Coord{X: int16(cols), Y: int16(rows)}, inR, outW, 0, &hpc); err != nil {
		closeAll(inR, inW, outR, outW)
		return nil, fmt.Errorf("pty: CreatePseudoConsole: %w", err)
	}

	attrs, err := windows.NewProcThreadAttributeList(1)
	if err != nil {
		windows.ClosePseudoConsole(hpc)
		closeAll(inR, inW, outR, outW)
		return nil, err
	}
	defer attrs.Delete()
	// The attribute's value is the HPCON itself, not a pointer to it.
	if err := attrs.Update(windows.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, *(*unsafe.Pointer)(unsafe.Pointer(&hpc)), unsafe.Sizeof(hpc)); err != nil {
		windows.ClosePseudoConsole(hpc)
		closeAll(inR, inW, outR, outW)
		return nil, fmt.Errorf("pty: attribute: %w", err)
	}

	si := &windows.StartupInfoEx{}
	si.Cb = uint32(unsafe.Sizeof(*si))
	// Null std handles + USESTDHANDLES: the child must get the
	// pseudoconsole's handles, never this process's (redirected) stdio.
	si.Flags = windows.STARTF_USESTDHANDLES
	si.ProcThreadAttributeList = attrs.List()

	var appPtr *uint16
	if app != "" {
		appPtr, _ = windows.UTF16PtrFromString(app)
	}
	cmdPtr, err := windows.UTF16PtrFromString(cmdline)
	if err != nil {
		windows.ClosePseudoConsole(hpc)
		closeAll(inR, inW, outR, outW)
		return nil, err
	}
	var dirPtr *uint16
	if spec.Dir != "" {
		if dirPtr, err = windows.UTF16PtrFromString(spec.Dir); err != nil {
			windows.ClosePseudoConsole(hpc)
			closeAll(inR, inW, outR, outW)
			return nil, err
		}
	}
	envBlock := environBlock(spec.Env)
	var envPtr *uint16
	if envBlock != nil {
		envPtr = &envBlock[0]
	}

	flags := uint32(windows.EXTENDED_STARTUPINFO_PRESENT | windows.CREATE_UNICODE_ENVIRONMENT | windows.CREATE_SUSPENDED)
	var pi windows.ProcessInformation
	if err := windows.CreateProcess(appPtr, cmdPtr, nil, nil, false, flags, envPtr, dirPtr, &si.StartupInfo, &pi); err != nil {
		windows.ClosePseudoConsole(hpc)
		closeAll(inR, inW, outR, outW)
		return nil, fmt.Errorf("pty: CreateProcess %s: %w", cmdline, err)
	}

	// The whole tree lives in a job: listed via the job, killed with it.
	job, jerr := newJob()
	if jerr == nil {
		if err := windows.AssignProcessToJobObject(job, pi.Process); err != nil {
			windows.CloseHandle(job)
			job = 0
		}
	}
	windows.ResumeThread(pi.Thread)
	windows.CloseHandle(pi.Thread)
	// Only the pseudoconsole keeps the far ends now; leaving ours open
	// would keep the output pipe from ever breaking.
	closeAll(inR, outW)

	p := &Process{
		hpc: hpc, job: job, proc: pi.Process, procOpen: true,
		outR: outR, inW: inW,
		done: make(chan struct{}), closed: make(chan struct{}),
	}
	p.pid = int(pi.ProcessId)
	var ct, et, kt, ut windows.Filetime
	if windows.GetProcessTimes(pi.Process, &ct, &et, &kt, &ut) == nil {
		p.started = time.Unix(0, ct.Nanoseconds())
	} else {
		p.started = time.Now()
	}
	go p.wait()
	return p, nil
}

func newJob() (windows.Handle, error) {
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return 0, err
	}
	var li windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION
	// No BREAKAWAY_OK: MSYS/Cygwin (Git Bash) start every child with
	// CREATE_BREAKAWAY_FROM_JOB whenever the job allows it, which would take
	// the whole tree out of the job (untracked, unkillable with the
	// window). Without it they check the limit and stay in.
	li.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if _, err := windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation,
		uintptr(unsafe.Pointer(&li)), uint32(unsafe.Sizeof(li))); err != nil {
		windows.CloseHandle(job)
		return 0, err
	}
	return job, nil
}

func (p *Process) wait() {
	windows.WaitForSingleObject(p.proc, windows.INFINITE)
	var code uint32
	windows.GetExitCodeProcess(p.proc, &code)
	p.exitCode = int(int32(code))
	p.pmu.Lock()
	windows.CloseHandle(p.proc)
	p.procOpen = false
	p.pmu.Unlock()
	close(p.done)
}

// Read reads the console's output.
func (p *Process) Read(b []byte) (int, error) {
	if len(b) == 0 {
		return 0, nil
	}
	p.rmu.Lock()
	defer p.rmu.Unlock()
	if p.outClosed {
		return 0, io.EOF
	}
	var n uint32
	err := windows.ReadFile(p.outR, b, &n, nil)
	if err != nil {
		if errors.Is(err, windows.ERROR_BROKEN_PIPE) || errors.Is(err, windows.ERROR_INVALID_HANDLE) || n == 0 {
			return int(n), io.EOF
		}
		return int(n), err
	}
	if n == 0 {
		return 0, io.EOF
	}
	return int(n), nil
}

// Write sends input to the console.
func (p *Process) Write(b []byte) (int, error) {
	p.wmu.Lock()
	defer p.wmu.Unlock()
	if p.inClosed {
		return 0, os.ErrClosed
	}
	total := 0
	for total < len(b) {
		var n uint32
		if err := windows.WriteFile(p.inW, b[total:], &n, nil); err != nil {
			return total, err
		}
		total += int(n)
	}
	return total, nil
}

// Resize changes the console size.
func (p *Process) Resize(cols, rows int) error {
	select {
	case <-p.closed:
		return os.ErrClosed
	default:
	}
	s := Spec{Cols: cols, Rows: rows}
	c, r := s.size()
	return windows.ResizePseudoConsole(p.hpc, windows.Coord{X: int16(c), Y: int16(r)})
}

// Wait blocks until the root child exits; its exit code.
func (p *Process) Wait() int {
	<-p.done
	return p.exitCode
}

// Done is closed when the root child has exited.
func (p *Process) Done() <-chan struct{} { return p.done }

// Kill terminates the whole process tree.
func (p *Process) Kill() error {
	p.pmu.Lock()
	defer p.pmu.Unlock()
	if p.job != 0 {
		if err := windows.TerminateJobObject(p.job, 1); err == nil {
			return nil
		}
	}
	if !p.procOpen {
		return nil
	}
	return windows.TerminateProcess(p.proc, 1)
}

// Pids lists every process in the tree (the job's members).
func (p *Process) Pids() []int {
	p.pmu.Lock()
	defer p.pmu.Unlock()
	if p.job != 0 {
		if pids, err := jobPids(p.job); err == nil {
			return pids
		}
	}
	if !p.procOpen {
		return nil
	}
	return []int{p.pid}
}

func jobPids(job windows.Handle) ([]int, error) {
	n := 256
	for {
		// JOBOBJECT_BASIC_PROCESS_ID_LIST: two DWORDs then ULONG_PTRs.
		hdr := unsafe.Sizeof(uintptr(0))
		buf := make([]uintptr, 1+n) // the header fits in one ULONG_PTR on 64-bit
		if hdr < 8 {
			buf = make([]uintptr, 2+n)
		}
		err := windows.QueryInformationJobObject(job, windows.JobObjectBasicProcessIdList,
			uintptr(unsafe.Pointer(&buf[0])), uint32(len(buf))*uint32(hdr), nil)
		assigned := *(*uint32)(unsafe.Pointer(&buf[0]))
		listed := *(*uint32)(unsafe.Add(unsafe.Pointer(&buf[0]), 4))
		if err != nil && !errors.Is(err, windows.ERROR_MORE_DATA) {
			return nil, err
		}
		if int(assigned) > n && n < 65536 {
			n = int(assigned) + 16
			continue
		}
		off := 8 / int(hdr)
		out := make([]int, 0, listed)
		for i := 0; i < int(listed) && off+i < len(buf); i++ {
			out = append(out, int(buf[off+i]))
		}
		return out, nil
	}
}

// Close shuts the pseudoconsole (letting Read drain to io.EOF), and kills
// what is left of the tree. It does not block.
func (p *Process) Close() error {
	p.closeOnce.Do(func() {
		close(p.closed)
		go func() {
			// ClosePseudoConsole renders the last frame and waits for the
			// output to be read (the reader keeps reading until EOF).
			windows.ClosePseudoConsole(p.hpc)
			p.wmu.Lock()
			p.inClosed = true
			windows.CloseHandle(p.inW)
			p.wmu.Unlock()
			p.rmu.Lock()
			p.outClosed = true
			windows.CloseHandle(p.outR)
			p.rmu.Unlock()
			p.pmu.Lock()
			if p.job != 0 {
				windows.CloseHandle(p.job) // KILL_ON_JOB_CLOSE
				p.job = 0
			}
			p.pmu.Unlock()
		}()
	})
	return nil
}

// commandLine resolves what CreateProcess gets: an application name ("" =
// let it search) and the command line.
func commandLine(spec Spec) (string, string, error) {
	if spec.Cmdline != "" {
		return "", spec.Cmdline, nil
	}
	if len(spec.Argv) == 0 || spec.Argv[0] == "" {
		return "", "", ErrNoCommand
	}
	env := spec.Env
	if env == nil {
		env = os.Environ()
	}
	path, err := LookPath(spec.Argv[0], env, spec.Dir)
	if err != nil {
		return "", "", err
	}
	ext := strings.ToLower(filepath.Ext(path))
	if ext == ".cmd" || ext == ".bat" {
		// Batch files run under cmd.exe; /s /c "<whole line>" keeps quotes.
		comspec, ok := envLookup(env, "ComSpec", true)
		if !ok || comspec == "" {
			comspec = filepath.Join(os.Getenv("SystemRoot"), "System32", "cmd.exe")
		}
		parts := []string{syscall.EscapeArg(path)}
		for _, a := range spec.Argv[1:] {
			parts = append(parts, syscall.EscapeArg(a))
		}
		return comspec, "cmd.exe /d /s /c \"" + strings.Join(parts, " ") + "\"", nil
	}
	parts := []string{syscall.EscapeArg(spec.Argv[0])}
	for _, a := range spec.Argv[1:] {
		parts = append(parts, syscall.EscapeArg(a))
	}
	return path, strings.Join(parts, " "), nil
}

// LookPath finds name the way cmd.exe would: a path is used as is (PATHEXT
// tried when it has no extension), a bare name is searched in dir then on
// env's PATH.
func LookPath(name string, env []string, dir string) (string, error) {
	pathext, ok := envLookup(env, "PATHEXT", true)
	if !ok || pathext == "" {
		pathext = ".COM;.EXE;.BAT;.CMD"
	}
	var exts []string
	for _, e := range strings.Split(strings.ToLower(pathext), ";") {
		if e = strings.TrimSpace(e); e != "" {
			if e[0] != '.' {
				e = "." + e
			}
			exts = append(exts, e)
		}
	}
	try := func(base string) (string, bool) {
		if filepath.Ext(base) != "" {
			if fi, err := os.Stat(base); err == nil && !fi.IsDir() {
				return base, true
			}
		}
		for _, e := range exts {
			if fi, err := os.Stat(base + e); err == nil && !fi.IsDir() {
				return base + e, true
			}
		}
		return "", false
	}
	if strings.ContainsAny(name, `\/:`) {
		p := name
		if !filepath.IsAbs(p) && dir != "" {
			p = filepath.Join(dir, p)
		}
		if r, ok := try(p); ok {
			return r, nil
		}
		return "", fmt.Errorf("pty: %s: not found", name)
	}
	if dir != "" {
		if r, ok := try(filepath.Join(dir, name)); ok {
			return r, nil
		}
	}
	pathVar, _ := envLookup(env, "PATH", true)
	for _, d := range filepath.SplitList(pathVar) {
		d = strings.Trim(d, `"`)
		if d == "" {
			continue
		}
		if r, ok := try(filepath.Join(d, name)); ok {
			return r, nil
		}
	}
	return "", fmt.Errorf("pty: %s: not found on PATH", name)
}

// environBlock is env as a CreateProcess UTF-16 block (nil = inherit).
func environBlock(env []string) []uint16 {
	if env == nil {
		return nil
	}
	// A repeated name: the last value wins (as os/exec does); Windows
	// itself would see the first.
	last := map[string]int{}
	for i, kv := range env {
		if j := indexEq(kv); j > 0 {
			last[strings.ToUpper(kv[:j])] = i
		}
	}
	var b []uint16
	for i, kv := range env {
		if kv == "" || strings.IndexByte(kv, 0) >= 0 {
			continue
		}
		if j := indexEq(kv); j > 0 && last[strings.ToUpper(kv[:j])] != i {
			continue
		}
		b = append(b, utf16.Encode([]rune(kv))...)
		b = append(b, 0)
	}
	if len(b) == 0 {
		b = append(b, 0)
	}
	return append(b, 0)
}
