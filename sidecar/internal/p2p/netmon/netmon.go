// Package netmon watches for network path changes (Wi-Fi switch, VPN up or
// down, a new interface): the Swift's NWPathMonitor handler in
// P2PBroker.swift. On Windows it wakes on NotifyIpInterfaceChange; elsewhere
// (and as a backstop) it polls the interface addresses.
//
// The signature is the Swift's idea of "which network am I on": whether
// any real interface is up, the real transport interfaces (no VPN or tunnel
// adapters: they flap), and the IPv4 address of the preferred one. Not
// IPv6 (privacy addresses rotate on their own).
package netmon

import (
	"net"
	"sort"
	"strings"
	"sync"
	"time"
)

// Update is one recomputed path.
type Update struct {
	Signature string
	Usable    bool // the Swift's path.status == .satisfied
}

// Monitor calls Handler with every recomputed path (often unchanged: the
// caller compares signatures, as the Swift does).
type Monitor struct {
	Handler func(Update)
	// PollEvery is the polling period (5 s; 30 s backstop on Windows).
	PollEvery time.Duration

	once sync.Once
	stop chan struct{}
	kick chan struct{}
}

// Start runs the monitor until Stop.
func (m *Monitor) Start() {
	m.once.Do(func() {
		m.stop = make(chan struct{})
		m.kick = make(chan struct{}, 1)
		poll := m.PollEvery
		if poll == 0 {
			poll = 5 * time.Second
			if notifySupported {
				poll = 30 * time.Second
			}
		}
		cancel := startNotify(m.Kick)
		go func() {
			defer cancel()
			t := time.NewTicker(poll)
			defer t.Stop()
			m.emit()
			for {
				select {
				case <-m.stop:
					return
				case <-t.C:
				case <-m.kick:
					// Debounce a burst of interface notifications.
					time.Sleep(750 * time.Millisecond)
					select {
					case <-m.kick:
					default:
					}
				}
				m.emit()
			}
		}()
	})
}

// Kick recomputes now.
func (m *Monitor) Kick() {
	select {
	case m.kick <- struct{}{}:
	default:
	}
}

// Stop ends the monitor.
func (m *Monitor) Stop() {
	if m.stop != nil {
		select {
		case <-m.stop:
		default:
			close(m.stop)
		}
	}
}

func (m *Monitor) emit() {
	if m.Handler != nil {
		m.Handler(Current())
	}
}

// virtualPrefixes are adapters that aren't a network a peer path rides:
// tunnels/VPNs, VM and container bridges, Apple's peer-to-peer radios.
var virtualPrefixes = []string{
	"utun", "ipsec", "tun", "tap", "ppp", "gif", "stf", "awdl", "llw", "anpi", "ap", "bridge",
	"docker", "br-", "veth", "virbr", "vmnet", "vboxnet", "zt", "tailscale", "wg", "lo",
	"vethernet", "vmware", "virtualbox", "hyper-v", "bluetooth", "loopback", "isatap", "teredo",
	"wsl", "npcap", "openvpn", "wintun", "nordlynx", "zerotier",
}

func isVirtual(name string) bool {
	n := strings.ToLower(name)
	for _, p := range virtualPrefixes {
		if strings.HasPrefix(n, p) {
			return true
		}
	}
	return strings.Contains(n, "virtual") || strings.Contains(n, "vpn") || strings.Contains(n, "pseudo")
}

// Current computes the path now.
func Current() Update {
	ifs, err := net.Interfaces()
	if err != nil {
		return Update{}
	}
	var names, own []string
	for _, ifc := range ifs {
		if ifc.Flags&net.FlagUp == 0 || ifc.Flags&net.FlagLoopback != 0 || isVirtual(ifc.Name) {
			continue
		}
		addrs, _ := ifc.Addrs()
		var v4 []string
		for _, a := range addrs {
			ipn, ok := a.(*net.IPNet)
			if !ok {
				continue
			}
			ip := ipn.IP.To4()
			if ip == nil || ip.IsLinkLocalUnicast() || ip.IsLoopback() {
				continue
			}
			v4 = append(v4, ifc.Name+"="+ip.String())
		}
		if len(v4) == 0 {
			continue // no usable IPv4: not carrying traffic for us
		}
		names = append(names, ifc.Name)
		own = append(own, v4...)
	}
	return Update{Signature: Signature(len(names) > 0, names, own), Usable: len(names) > 0}
}

// Signature is "<status>|<sorted transports>|<sorted own addresses>". Go
// can't tell the preferred interface the way NWPath does, so every real
// interface's IPv4 counts (a second Wi-Fi on the same adapter still shows).
func Signature(usable bool, transports, addresses []string) string {
	status := "unsatisfied"
	if usable {
		status = "satisfied"
	}
	t := dedupeSorted(transports)
	a := dedupeSorted(addresses)
	return status + "|" + strings.Join(t, ",") + "|" + strings.Join(a, ",")
}

func dedupeSorted(xs []string) []string {
	m := map[string]bool{}
	var out []string
	for _, x := range xs {
		if !m[x] {
			m[x] = true
			out = append(out, x)
		}
	}
	sort.Strings(out)
	return out
}
