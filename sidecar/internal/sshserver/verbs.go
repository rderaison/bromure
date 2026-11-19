package sshserver

import (
	"encoding/base64"
	"strconv"
	"strings"
	"unicode/utf8"
)

// The fat-client SSH exec verbs (FatClient.swift), exact strings.
const (
	ControlVerb             = "bromure-fatclient/1 control"
	ForwardVerbPrefix       = "bromure-fatclient/1 forward "
	ForwardUDPVerbPrefix    = "bromure-fatclient/1 forward-udp "
	BrowserMCPVerbPrefix    = "bromure-fatclient/1 browser-mcp "
	DelegationMCPVerb       = "bromure-fatclient/1 delegation-mcp"
	MachineLinkVerbPrefix   = "bromure-fatclient/1 machine-link "
	MachineDetachVerbPrefix = "bromure-fatclient/1 machine-detach "
)

// fields splits on single spaces, empty runs omitted (Swift's split).
func fields(s string) []string {
	return strings.FieldsFunc(s, func(r rune) bool { return r == ' ' })
}

// ParseForward parses `<prefix><ip> <port>`.
func ParseForward(cmd string) (ip string, port int, ok bool) {
	if !strings.HasPrefix(cmd, ForwardVerbPrefix) {
		return "", 0, false
	}
	p := fields(cmd[len(ForwardVerbPrefix):])
	if len(p) != 2 {
		return "", 0, false
	}
	n, err := strconv.Atoi(p[1])
	if err != nil || n <= 0 || n >= 65536 {
		return "", 0, false
	}
	return p[0], n, true
}

// ParseForwardUDP parses `<prefix><ip>`.
func ParseForwardUDP(cmd string) (string, bool) {
	if !strings.HasPrefix(cmd, ForwardUDPVerbPrefix) {
		return "", false
	}
	ip := strings.Trim(cmd[len(ForwardUDPVerbPrefix):], " \t")
	return ip, ip != ""
}

// ParseBrowserMCP parses `<prefix><workspace>`.
func ParseBrowserMCP(cmd string) (string, bool) {
	if !strings.HasPrefix(cmd, BrowserMCPVerbPrefix) {
		return "", false
	}
	vm := strings.Trim(cmd[len(BrowserMCPVerbPrefix):], " \t")
	return vm, vm != ""
}

// ParseUUID parses a UUID string as Foundation's UUID(uuidString:) does
// (8-4-4-4-12 hex, either case) and returns its uuidString (upper case).
func ParseUUID(s string) (string, bool) {
	if len(s) != 36 {
		return "", false
	}
	for i := 0; i < 36; i++ {
		c := s[i]
		switch i {
		case 8, 13, 18, 23:
			if c != '-' {
				return "", false
			}
		default:
			if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
				return "", false
			}
		}
	}
	return strings.ToUpper(s), true
}

// ParseMachineLink parses `<prefix><uuid> <base64 name>`.
func ParseMachineLink(cmd string) (id, name string, ok bool) {
	if !strings.HasPrefix(cmd, MachineLinkVerbPrefix) {
		return "", "", false
	}
	p := fields(cmd[len(MachineLinkVerbPrefix):])
	if len(p) != 2 {
		return "", "", false
	}
	id, ok = ParseUUID(p[0])
	if !ok {
		return "", "", false
	}
	raw, err := base64.StdEncoding.DecodeString(p[1])
	if err != nil || !utf8.Valid(raw) {
		return "", "", false
	}
	return id, string(raw), true
}

// ParseMachineDetach parses `<prefix><uuid>`.
func ParseMachineDetach(cmd string) (string, bool) {
	if !strings.HasPrefix(cmd, MachineDetachVerbPrefix) {
		return "", false
	}
	return ParseUUID(strings.TrimSpace(cmd[len(MachineDetachVerbPrefix):]))
}

// MachineLinkVerb is the exec a Sidecar parks a link with.
func MachineLinkVerb(id, name string) string {
	return MachineLinkVerbPrefix + id + " " + base64.StdEncoding.EncodeToString([]byte(name))
}

// MachineDetachVerb is the exec a Sidecar detaches with.
func MachineDetachVerb(id string) string { return MachineDetachVerbPrefix + id }
