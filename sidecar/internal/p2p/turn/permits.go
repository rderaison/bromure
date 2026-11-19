package turn

import "net"

// RelayPermits is the peer addresses a relay allocation lets in
// (TurnRelayTransport.swift RelayPermits). Installed only once
// CreatePermission succeeded; failures are retried up to MaxTries. Only
// public unicast addresses, at most MaxAddresses: the permissions are the
// network ACL in front of the SSH server and the addresses come from the
// peer's unsigned signalling. Not thread-safe; its listener locks it.
type RelayPermits struct {
	Installed []string
	pending   []pendingIP
	inFlight  map[string]bool
	admit     func(string) bool
}

type pendingIP struct {
	IP    string
	Tries int
}

const (
	MaxTries     = 6
	MaxAddresses = 4
	RenewalTries = 3
)

// NewRelayPermits starts with the installed and queued addresses.
func NewRelayPermits(installed, pending []string, admit func(string) bool) *RelayPermits {
	if admit == nil {
		admit = IsPublicUnicast
	}
	p := &RelayPermits{inFlight: map[string]bool{}, admit: admit}
	for _, ip := range installed {
		if admit(ip) && len(p.Installed) < MaxAddresses {
			p.Installed = append(p.Installed, ip)
		}
	}
	for _, ip := range pending {
		p.Add(ip)
	}
	return p
}

// Admissible is the addresses of ips a relay may let in: admitted,
// distinct, at most MaxAddresses, in order.
func Admissible(ips []string, admit func(string) bool) []string {
	if admit == nil {
		admit = IsPublicUnicast
	}
	var out []string
	for _, ip := range ips {
		if admit(ip) && !contains(out, ip) && len(out) < MaxAddresses {
			out = append(out, ip)
		}
	}
	return out
}

func (p *RelayPermits) isPending(ip string) bool {
	for _, q := range p.pending {
		if q.IP == ip {
			return true
		}
	}
	return false
}

// Add queues a new address; false when it isn't admissible or the cap is
// reached, true when installed or queued.
func (p *RelayPermits) Add(ip string) bool {
	if contains(p.Installed, ip) || p.inFlight[ip] || p.isPending(ip) {
		return true
	}
	if !p.admit(ip) || len(p.Installed)+len(p.pending)+len(p.inFlight) >= MaxAddresses {
		return false
	}
	p.pending = append(p.pending, pendingIP{ip, 0})
	return true
}

// TakeOne is the next queued address to try (taken off the queue).
func (p *RelayPermits) TakeOne() (string, int, bool) {
	if len(p.pending) == 0 {
		return "", 0, false
	}
	n := p.pending[0]
	p.pending = p.pending[1:]
	p.inFlight[n.IP] = true
	return n.IP, n.Tries, true
}

// Record is how a try went; true when a failure is queued again.
func (p *RelayPermits) Record(ip string, tries int, ok bool) bool {
	delete(p.inFlight, ip)
	if ok {
		if !contains(p.Installed, ip) {
			p.Installed = append(p.Installed, ip)
		}
		return false
	}
	if tries+1 >= MaxTries || p.isPending(ip) {
		return false
	}
	p.pending = append(p.pending, pendingIP{ip, tries + 1})
	return true
}

// RenewalFailed requeues an installed address for a couple more tries.
func (p *RelayPermits) RenewalFailed(ip string) {
	if p.isPending(ip) {
		return
	}
	p.pending = append(p.pending, pendingIP{ip, MaxTries - RenewalTries})
}

// IsPublicUnicast: a numeric, globally routable unicast address. Not
// private, loopback, link-local, CGNAT, documentation, benchmark,
// multicast, reserved or unspecified.
func IsPublicUnicast(ip string) bool {
	a := net.ParseIP(ip)
	if a == nil {
		return false
	}
	if v4 := a.To4(); v4 != nil && !isV6Text(ip) {
		x := uint32(v4[0])<<24 | uint32(v4[1])<<16 | uint32(v4[2])<<8 | uint32(v4[3])
		blocked := [][2]uint32{
			{0x00000000, 8}, {0x0A000000, 8}, {0x64400000, 10}, {0x7F000000, 8},
			{0xA9FE0000, 16}, {0xAC100000, 12}, {0xC0000000, 24}, {0xC0000200, 24},
			{0xC0A80000, 16}, {0xC6120000, 15}, {0xC6336400, 24}, {0xCB007100, 24},
			{0xE0000000, 4}, {0xF0000000, 4},
		}
		for _, b := range blocked {
			if x>>(32-b[1]) == b[0]>>(32-b[1]) {
				return false
			}
		}
		return true
	}
	b := a.To16()
	if b[0]&0xE0 != 0x20 {
		return false
	}
	return !(b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0D && b[3] == 0xB8)
}

func isV6Text(ip string) bool {
	for i := 0; i < len(ip); i++ {
		if ip[i] == ':' {
			return true
		}
	}
	return false
}
