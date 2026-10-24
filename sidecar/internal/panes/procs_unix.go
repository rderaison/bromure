//go:build !windows

package panes

import (
	"bufio"
	"bytes"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// windowProcs: one `ps -A` for everything, each window's tree being its
// root child's descendants.
func windowProcs(ws []*window) map[*window][]*procInfo {
	out := map[*window][]*procInfo{}
	raw, err := exec.Command("ps", "-A", "-ww", "-o", "pid=,ppid=,lstart=,args=").Output()
	if err != nil {
		return out
	}
	all := parsePS(raw)
	kids := map[int][]*procInfo{}
	for _, p := range all {
		kids[p.ppid] = append(kids[p.ppid], p)
	}
	byPid := map[int]*procInfo{}
	for _, p := range all {
		byPid[p.pid] = p
	}
	for _, w := range ws {
		root := byPid[w.proc.Pid()]
		if root == nil {
			continue
		}
		var list []*procInfo
		seen := map[int]bool{}
		var walk func(p *procInfo)
		walk = func(p *procInfo) {
			if seen[p.pid] {
				return
			}
			seen[p.pid] = true
			list = append(list, p)
			for _, k := range kids[p.pid] {
				walk(k)
			}
		}
		walk(root)
		out[w] = list
	}
	return out
}

// parsePS reads `pid ppid <lstart: 5 words> args…` lines.
func parsePS(raw []byte) []*procInfo {
	var out []*procInfo
	sc := bufio.NewScanner(bytes.NewReader(raw))
	sc.Buffer(make([]byte, 64*1024), 1<<20)
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) < 8 {
			continue
		}
		pid, e1 := strconv.Atoi(f[0])
		ppid, e2 := strconv.Atoi(f[1])
		if e1 != nil || e2 != nil {
			continue
		}
		start, _ := time.ParseInLocation("Mon Jan 2 15:04:05 2006", strings.Join(f[2:7], " "), time.Local)
		// args keeps its own spacing: cut after the 7th field.
		line := sc.Text()
		rest := line
		for i := 0; i < 7; i++ {
			rest = strings.TrimLeft(rest, " \t")
			if j := strings.IndexAny(rest, " \t"); j >= 0 {
				rest = rest[j:]
			} else {
				rest = ""
			}
		}
		args := strings.TrimLeft(rest, " \t")
		out = append(out, &procInfo{pid: pid, ppid: ppid, exe: exeBase(firstField(args)), args: args, start: start})
	}
	return out
}

func firstField(s string) string {
	if i := strings.IndexAny(s, " \t"); i >= 0 {
		return s[:i]
	}
	return s
}
