//go:build windows

package panes

import (
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

// windowProcs: each window's job members, with parent and exe from one
// toolhelp snapshot, command line (NtQueryInformationProcess) and start
// time (GetProcessTimes) per member.
func windowProcs(ws []*window) map[*window][]*procInfo {
	type entry struct {
		ppid int
		exe  string
	}
	all := map[int]entry{}
	if snap, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0); err == nil {
		var pe windows.ProcessEntry32
		pe.Size = uint32(unsafe.Sizeof(pe))
		for err := windows.Process32First(snap, &pe); err == nil; err = windows.Process32Next(snap, &pe) {
			all[int(pe.ProcessID)] = entry{int(pe.ParentProcessID), windows.UTF16ToString(pe.ExeFile[:])}
		}
		windows.CloseHandle(snap)
	}
	out := map[*window][]*procInfo{}
	for _, w := range ws {
		for _, pid := range w.proc.Pids() {
			e, ok := all[pid]
			if !ok {
				continue // gone since the job was listed
			}
			p := &procInfo{pid: pid, ppid: e.ppid, exe: exeBase(e.exe)}
			cmd, start := processDetails(pid)
			if cmd == "" {
				cmd = e.exe
			}
			p.args = posixArgs(cmd)
			p.start = start
			if pid == w.proc.Pid() {
				p.start = w.proc.StartedAt()
			}
			out[w] = append(out[w], p)
		}
	}
	return out
}

func processDetails(pid int) (string, time.Time) {
	h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(pid))
	if err != nil {
		return "", time.Time{}
	}
	defer windows.CloseHandle(h)
	var start time.Time
	var ct, et, kt, ut windows.Filetime
	if windows.GetProcessTimes(h, &ct, &et, &kt, &ut) == nil {
		start = time.Unix(0, ct.Nanoseconds())
	}
	return commandLine(h), start
}

// commandLine reads a process's command line (Windows 8.1+).
func commandLine(h windows.Handle) string {
	size := uint32(4096)
	for tries := 0; tries < 4; tries++ {
		buf := make([]byte, size)
		var ret uint32
		err := windows.NtQueryInformationProcess(h, windows.ProcessCommandLineInformation,
			unsafe.Pointer(&buf[0]), size, &ret)
		if err == nil {
			us := (*windows.NTUnicodeString)(unsafe.Pointer(&buf[0]))
			return us.String()
		}
		if err == windows.STATUS_INFO_LENGTH_MISMATCH || err == windows.STATUS_BUFFER_TOO_SMALL || err == windows.STATUS_BUFFER_OVERFLOW {
			if ret > size {
				size = ret
			} else {
				size *= 4
			}
			continue
		}
		return ""
	}
	return ""
}
