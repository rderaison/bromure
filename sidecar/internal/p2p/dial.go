package p2p

import (
	"net"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/p2p/signal"
	"github.com/rderaison/bromure/sidecar/internal/p2p/sockopt"
)

// Path is which rung carried a session (P2PPath).
type Path string

const (
	PathLAN    Path = "lan"
	PathDirect Path = "direct"
	PathRelay  Path = "relay"
)

// ReportKind is the telemetry pathKind.
func (p Path) ReportKind() string {
	if p == PathRelay {
		return "relay"
	}
	return "direct"
}

// Label is the UI pill text.
func (p Path) Label() string {
	switch p {
	case PathLAN:
		return "Direct (LAN)"
	case PathRelay:
		return "Relayed"
	}
	return "Direct"
}

func pathFor(c signal.Candidate) Path {
	if c.Kind == signal.KindRelay {
		return PathRelay
	}
	if c.Kind == signal.KindHost && isPrivate(c.IP) {
		return PathLAN
	}
	return PathDirect
}

func isPrivate(ip string) bool {
	if strings.HasPrefix(ip, "10.") || strings.HasPrefix(ip, "192.168.") {
		return true
	}
	if strings.HasPrefix(ip, "172.") {
		parts := strings.Split(ip, ".")
		if len(parts) > 1 {
			if n, err := strconv.Atoi(parts[1]); err == nil && n >= 16 && n <= 31 {
				return true
			}
		}
	}
	return strings.HasPrefix(strings.ToLower(ip), "fe80")
}

// ConnectCandidate is a bounded TCP connect to a numeric candidate, tuned
// interactive (P2PTCP.connect). Swappable in tests.
var ConnectCandidate = func(c signal.Candidate, timeout time.Duration) (net.Conn, error) {
	conn, err := net.DialTimeout("tcp", net.JoinHostPort(c.IP, strconv.Itoa(c.Port)), timeout)
	if err != nil {
		return nil, err
	}
	sockopt.TuneInteractive(conn, true)
	return conn, nil
}

type win struct {
	cand signal.Candidate
	conn net.Conn
	path Path
}

const (
	maxConcurrent  = 24
	upgradeGrace   = 250 * time.Millisecond
	patientTimeout = 3 * time.Second
)

// dialCandidates races every TCP candidate (P2PDirectDialer.dial): an
// impatient 1 s pass, then a patient 3 s one if nothing answered. The UDP
// relay is not ported, so only TCP candidates race.
func dialCandidates(cands []signal.Candidate, perCandidate time.Duration, deadline time.Time) *win {
	var ordered []signal.Candidate
	for _, c := range cands {
		if c.Proto == signal.ProtoTCP {
			ordered = append(ordered, c)
		}
	}
	sort.SliceStable(ordered, func(i, j int) bool { return ordered[i].Prio > ordered[j].Prio })
	if len(ordered) > maxConcurrent {
		ordered = ordered[:maxConcurrent]
	}
	if len(ordered) == 0 {
		return nil
	}
	if w := race(ordered, perCandidate, deadline); w != nil {
		return w
	}
	if perCandidate >= patientTimeout {
		return nil
	}
	return race(ordered, patientTimeout, deadline)
}

type raceResult struct {
	w  *win
	ok bool
}

// race dials every candidate at once; the best that connects wins, after
// upgradeGrace for a better one. Losers' connections are closed.
func race(ordered []signal.Candidate, budget time.Duration, deadline time.Time) *win {
	if left := time.Until(deadline); left < budget {
		budget = left
	}
	if budget <= 0 {
		return nil
	}
	top := ordered[0].Prio
	results := make(chan raceResult, len(ordered))
	for _, c := range ordered {
		go func(c signal.Candidate) {
			t0 := time.Now()
			conn, err := ConnectCandidate(c, budget)
			ms := int(time.Since(t0) / time.Millisecond)
			if err != nil {
				logx.Printf("p2p: dial %s %s:%d FAILED (%dms budget %dms)", c.Kind, c.IP, c.Port, ms, int(budget/time.Millisecond))
				results <- raceResult{}
				return
			}
			logx.Printf("p2p: dial %s %s:%d OK (%dms)", c.Kind, c.IP, c.Port, ms)
			results <- raceResult{&win{c, conn, pathFor(c)}, true}
		}(c)
	}
	var best *win
	var firstWin time.Time
	finished := 0
	timer := time.NewTimer(time.Until(deadline))
	defer timer.Stop()
	defer func() {
		// Late finishers drop their connections.
		left := len(ordered) - finished
		go func() {
			for i := 0; i < left; i++ {
				if r := <-results; r.ok {
					r.w.conn.Close()
				}
			}
		}()
	}()
	for {
		if finished >= len(ordered) {
			return best
		}
		if best != nil && best.cand.Prio >= top {
			return best
		}
		if !firstWin.IsZero() && time.Since(firstWin) >= upgradeGrace {
			return best
		}
		if !time.Now().Before(deadline) {
			return best
		}
		select {
		case r := <-results:
			finished++
			if !r.ok {
				continue
			}
			if best == nil {
				best = r.w
				firstWin = time.Now()
				wake := firstWin.Add(upgradeGrace)
				if wake.Before(deadline) {
					timer.Reset(time.Until(wake))
				}
			} else if r.w.cand.Prio > best.cand.Prio {
				best.conn.Close()
				best = r.w
			} else {
				r.w.conn.Close()
			}
		case <-timer.C:
			return best
		}
	}
}
