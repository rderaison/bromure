package turn

import (
	"net"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/logx"
)

// The pure pieces of TurnRelayTransport.swift: coturn `urls` parsing and
// endpoint selection, and the relay RTT ranking.

// HostPort is one parsed stun:/turn:/turns: URL.
type HostPort struct {
	Host      string
	Port      int
	Transport string // "" when the URL has none
}

// ParseHostPort parses `turn:host:3478?transport=tcp` (a bare host
// defaults to 3478).
func ParseHostPort(u string) (HostPort, bool) {
	i := strings.IndexByte(u, ':')
	if i < 0 {
		return HostPort{}, false
	}
	rest := u[i+1:]
	var transport string
	if q := strings.IndexByte(rest, '?'); q >= 0 {
		query := rest[q+1:]
		rest = rest[:q]
		for _, pair := range strings.Split(query, "&") {
			if pair == "" {
				continue
			}
			kv := strings.SplitN(pair, "=", 2)
			if len(kv) == 2 && kv[0] == "transport" {
				transport = kv[1]
			}
		}
	}
	if c := strings.LastIndexByte(rest, ':'); c >= 0 {
		if p, err := strconv.Atoi(rest[c+1:]); err == nil {
			return HostPort{rest[:c], p, transport}, true
		}
	}
	return HostPort{rest, 3478, transport}, true
}

// Endpoint is where the TURN client legs go.
type Endpoint struct {
	Host string
	Port int
	TLS  bool
}

// PreferredRelayEndpoint prefers `turns:…?transport=tcp` (TLS, 5349), else
// plain `turn:…?transport=tcp`.
func PreferredRelayEndpoint(urls []string) (Endpoint, bool) {
	for _, u := range urls {
		if strings.HasPrefix(u, "turns:") {
			if p, ok := ParseHostPort(u); ok && p.Transport == "tcp" {
				return Endpoint{p.Host, p.Port, true}, true
			}
		}
	}
	if p, ok := PreferredTCPEndpoint(urls); ok {
		return Endpoint{p.Host, p.Port, false}, true
	}
	return Endpoint{}, false
}

// PreferredTCPEndpoint is the plain `turn:…?transport=tcp` endpoint.
func PreferredTCPEndpoint(urls []string) (HostPort, bool) {
	for _, u := range urls {
		if strings.HasPrefix(u, "turn:") {
			if p, ok := ParseHostPort(u); ok && p.Transport == "tcp" {
				return p, true
			}
		}
	}
	return HostPort{}, false
}

// StunEndpoint is the `stun:` URL if present, else the TCP turn endpoint.
func StunEndpoint(urls []string) (HostPort, bool) {
	for _, u := range urls {
		if strings.HasPrefix(u, "stun:") {
			if p, ok := ParseHostPort(u); ok {
				return p, true
			}
		}
	}
	return PreferredTCPEndpoint(urls)
}

// DistinctHosts is the relay hosts in first-seen order.
func DistinctHosts(urls []string) []string {
	var hosts []string
	for _, u := range urls {
		if p, ok := ParseHostPort(u); ok && !contains(hosts, p.Host) {
			hosts = append(hosts, p.Host)
		}
	}
	return hosts
}

func urlsOfHost(urls []string, h string) []string {
	var out []string
	for _, u := range urls {
		if p, ok := ParseHostPort(u); ok && p.Host == h {
			out = append(out, u)
		}
	}
	return out
}

// StunEndpointsPerHost is one STUN endpoint per distinct relay host.
func StunEndpointsPerHost(urls []string) []HostPort {
	var out []HostPort
	for _, h := range DistinctHosts(urls) {
		if p, ok := StunEndpoint(urlsOfHost(urls, h)); ok {
			out = append(out, p)
		}
	}
	return out
}

// Regroup orders urls by a host ranking.
func Regroup(urls []string, order []string) []string {
	var out []string
	for _, h := range order {
		out = append(out, urlsOfHost(urls, h)...)
	}
	return out
}

// ProbeRTT is the TCP-connect RTT to host:port over the first of its
// addresses that connects (nil-equivalent false when none does).
var ProbeRTT = func(host string, port int, timeout time.Duration) (time.Duration, bool) {
	for _, ip := range ResolveAll(host) {
		t0 := time.Now()
		c, err := net.DialTimeout("tcp", net.JoinHostPort(ip, strconv.Itoa(port)), timeout)
		if err == nil {
			c.Close()
			return time.Since(t0), true
		}
	}
	return 0, false
}

// ResolveAll is every numeric address of host, in resolver order.
func ResolveAll(host string) []string {
	if net.ParseIP(host) != nil {
		return []string{host}
	}
	addrs, err := net.LookupHost(host)
	if err != nil {
		return nil
	}
	return addrs
}

// OrderURLsByRTT reorders urls so the lowest-RTT relay's URLs come first,
// probing at most limit distinct hosts in parallel. Unreachable hosts keep
// their relative order after the reachable ones.
func OrderURLsByRTT(urls []string, limit int, timeout time.Duration) []string {
	hosts := DistinctHosts(urls)
	probed := hosts
	if len(probed) > limit {
		probed = probed[:limit]
	}
	if len(probed) <= 1 {
		return urls
	}
	var mu sync.Mutex
	rtt := map[string]time.Duration{}
	done := make(chan struct{}, len(probed))
	for _, h := range probed {
		hu := urlsOfHost(urls, h)
		port := 3478
		if e, ok := PreferredRelayEndpoint(hu); ok {
			port = e.Port
		} else if len(hu) > 0 {
			if p, ok := ParseHostPort(hu[0]); ok {
				port = p.Port
			}
		}
		go func(h string, port int) {
			if r, ok := ProbeRTT(h, port, timeout); ok {
				mu.Lock()
				rtt[h] = r
				mu.Unlock()
			}
			done <- struct{}{}
		}(h, port)
	}
	wait := time.After(timeout + time.Second)
	for range probed {
		select {
		case <-done:
			continue
		case <-wait:
		}
		break
	}
	mu.Lock()
	measured := map[string]time.Duration{}
	for k, v := range rtt {
		measured[k] = v
	}
	mu.Unlock()
	var parts []string
	for _, h := range probed {
		if r, ok := measured[h]; ok {
			parts = append(parts, h+"="+strconv.Itoa(int(r/time.Millisecond))+"ms")
		} else {
			parts = append(parts, h+"=unreachable")
		}
	}
	logx.Printf("p2p: relay probe: %s", strings.Join(parts, " "))
	var reachable []string
	for _, h := range probed {
		if _, ok := measured[h]; ok {
			reachable = append(reachable, h)
		}
	}
	sort.SliceStable(reachable, func(i, j int) bool { return measured[reachable[i]] < measured[reachable[j]] })
	order := append([]string(nil), reachable...)
	for _, h := range hosts {
		if !contains(reachable, h) {
			order = append(order, h)
		}
	}
	return Regroup(urls, order)
}

func contains(xs []string, s string) bool {
	for _, x := range xs {
		if x == s {
			return true
		}
	}
	return false
}
