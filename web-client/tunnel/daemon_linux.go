package main

// The root half of the tunnel (`bromure-client-tunnel helper`): the Linux
// counterpart of the macOS FatClientTunnelDaemon. It only does what needs
// root — create a TUN, route one private /24 to it FOR THE CALLER'S UID ONLY,
// and hand the TUN fd to the caller over SCM_RIGHTS — then holds the
// connection open for the tunnel's lifetime and undoes everything when it
// closes. The packet work runs unprivileged in the caller (forward mode).
//
// Protocol (same as the Mac's): the client sends `SETUP <cidr>\n` and gets
// `OK <ifname>\n` with the fd as ancillary data, or `ERR <why>\n`.
//
// Who may ask (the socket is 0666; these checks do the gating, as on the Mac):
//   - root, or a user with an active logind session on a seat (the person at
//     the machine — the Mac's "console user");
//   - and only this program: the caller's executable must be this helper's own
//     file, which must be root-owned in root-owned directories (else only root
//     is served). Defense in depth, not the boundary: what bounds a caller is
//     the uid scoping below.
// What it does for them:
//   - one RFC 1918 / CGNAT /24 that no route covers yet (strictly spelled);
//   - `ip rule … uidrange <uid>-<uid>`: only the caller's own traffic is
//     routed to the TUN, never another user's;
//   - the TUN can inject packets into the host stack, so what arrives on it
//     is confined by an ingress filter (tc, part of iproute2): IPv4 from that
//     /24 only, everything else dropped — no spoofing as the LAN or as
//     localhost, no IPv6; forwarding is off on it, so nothing injected is
//     routed on.
// Teardown is idempotent and also runs at the start of every session for
// rules a killed helper left behind, so no uid is left black-holed.

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

const (
	helperSocket = "/run/bromure-client-tunnel.sock"
	maxTunnels   = 16
	tunPrefix    = "brc"
	tablBase     = 51800 // routing table = tablBase + TUN unit
	prefRoute    = 5180  // uidrange <uid> → the tunnel's table
)

var errDenied = errors.New("denied")

// helperMain runs the helper. Under systemd (bromure-client-tunnel.socket,
// Accept=yes) the connection is fd 3 and one process serves it; with
// `--listen PATH` it serves a socket itself (tests, systems without systemd).
func helperMain(args []string) int {
	log.SetFlags(0)
	log.SetPrefix("bromure-client-tunnel helper: ")
	if os.Geteuid() != 0 {
		log.Print("must run as root")
		return 1
	}
	os.Setenv("PATH", "/usr/sbin:/usr/bin:/sbin:/bin")
	// Every live tunnel is torn down on SIGTERM (systemd stopping the
	// socket, shutdown) before the process exits.
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	go func() {
		<-sig
		live.teardownAll()
		os.Exit(0)
	}()
	if len(args) == 2 && args[0] == "--listen" {
		return listenAndServe(args[1])
	}
	if os.Getenv("LISTEN_PID") == strconv.Itoa(os.Getpid()) && os.Getenv("LISTEN_FDS") == "1" {
		f := os.NewFile(3, "socket")
		c, err := net.FileConn(f)
		f.Close()
		if err != nil {
			log.Printf("socket: %v", err)
			return 1
		}
		serve(c.(*net.UnixConn))
		return 0
	}
	log.Print("usage: helper [--listen PATH] (or socket-activated by systemd)")
	return 2
}

func listenAndServe(path string) int {
	os.Remove(path)
	l, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		log.Print(err)
		return 1
	}
	os.Chmod(path, 0o666)
	var mu sync.Mutex
	active := 0
	for {
		c, err := l.AcceptUnix()
		if err != nil {
			log.Print(err)
			return 1
		}
		mu.Lock()
		if active >= maxTunnels {
			mu.Unlock()
			fmt.Fprintf(c, "ERR busy: %d tunnels already open\n", maxTunnels)
			c.Close()
			continue
		}
		active++
		mu.Unlock()
		go func() {
			serve(c)
			mu.Lock()
			active--
			mu.Unlock()
		}()
	}
}

// serve runs one tunnel: checks, SETUP, TUN + routes, fd handoff, hold,
// teardown.
func serve(c *net.UnixConn) {
	defer c.Close()
	fail := func(why string) {
		log.Printf("refused: %s", why)
		fmt.Fprintf(c, "ERR %s\n", strings.ReplaceAll(why, "\n", " "))
	}
	cred, err := peerCred(c)
	if err != nil {
		fail("can't identify the caller")
		return
	}
	if err := callerAllowed(cred); err != nil {
		fail(err.Error())
		return
	}
	cleanupStale()

	c.SetReadDeadline(time.Now().Add(10 * time.Second)) // a silent caller doesn't keep its slot
	line, err := readLine(c)
	if err != nil {
		fail("bad request")
		return
	}
	routes, err := routeTable()
	if err != nil {
		fail(err.Error())
		return
	}
	cidr, err := admit(line, routes)
	if err != nil {
		fail(err.Error())
		return
	}
	c.SetReadDeadline(time.Time{})

	t, err := setupTunnel(cidr, cred.Uid)
	if err != nil {
		fail(err.Error())
		return
	}
	live.add(t)
	defer live.remove(t)
	defer t.teardown()

	oob := syscall.UnixRights(int(t.file.Fd()))
	if _, _, err := c.WriteMsgUnix([]byte("OK "+t.name+"\n"), oob, nil); err != nil {
		log.Printf("handoff: %v", err)
		return
	}
	log.Printf("up: %s → %s for uid %d (pid %d)", cidr, t.name, cred.Uid, cred.Pid)
	// The tunnel lasts until the caller disconnects (or sends anything).
	var b [1]byte
	c.Read(b[:])
	log.Printf("down: %s (%s)", cidr, t.name)
}

func peerCred(c *net.UnixConn) (*syscall.Ucred, error) {
	raw, err := c.SyscallConn()
	if err != nil {
		return nil, err
	}
	var cred *syscall.Ucred
	var cerr error
	raw.Control(func(fd uintptr) {
		cred, cerr = syscall.GetsockoptUcred(int(fd), syscall.SOL_SOCKET, syscall.SO_PEERCRED)
	})
	return cred, cerr
}

// callerAllowed: root, or the seat's active user running this very program.
func callerAllowed(cred *syscall.Ucred) error {
	if cred.Uid == 0 {
		return nil
	}
	if !activeSeatUser(cred.Uid) {
		return fmt.Errorf("denied: uid %d has no active session at this machine", cred.Uid)
	}
	self, err := trustedSelf()
	if err != nil {
		return fmt.Errorf("denied: %v; only root is served", err)
	}
	exe, err := os.Readlink(fmt.Sprintf("/proc/%d/exe", cred.Pid))
	if err != nil || exe != self {
		return errors.New("unsigned: the caller isn't this helper's own program (" + self + ")")
	}
	return nil
}

// activeSeatUser: logind says the uid has an active session on a seat.
func activeSeatUser(uid uint32) bool {
	b, err := os.ReadFile(fmt.Sprintf("/run/systemd/users/%d", uid))
	if err != nil {
		return false
	}
	var state, seats string
	for _, l := range strings.Split(string(b), "\n") {
		if v, ok := strings.CutPrefix(l, "STATE="); ok {
			state = v
		}
		if v, ok := strings.CutPrefix(l, "ACTIVE_SEATS="); ok {
			seats = v
		}
	}
	return state == "active" && strings.TrimSpace(seats) != ""
}

// trustedSelf is this program's path, if it and every directory above it are
// root-owned and not writable by group or others (no one else could have
// swapped in a different file there).
func trustedSelf() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	exe, err = filepath.EvalSymlinks(exe)
	if err != nil {
		return "", err
	}
	for p := exe; ; p = filepath.Dir(p) {
		var st syscall.Stat_t
		if err := syscall.Stat(p, &st); err != nil {
			return "", err
		}
		if st.Uid != 0 || st.Mode&0o022 != 0 {
			return "", fmt.Errorf("%s isn't root-owned and protected", p)
		}
		if p == "/" {
			break
		}
	}
	return exe, nil
}

func readLine(c *net.UnixConn) (string, error) {
	var b []byte
	var one [1]byte
	for len(b) < 256 {
		n, err := c.Read(one[:])
		if n == 1 {
			if one[0] == '\n' {
				return string(b), nil
			}
			b = append(b, one[0])
		}
		if err != nil {
			return "", err
		}
	}
	return "", errors.New("line too long")
}

// live is every tunnel this process holds (several in --listen mode).
var live = &tunnels{m: map[*tunnel]bool{}}

type tunnels struct {
	mu sync.Mutex
	m  map[*tunnel]bool
}

func (l *tunnels) add(t *tunnel)    { l.mu.Lock(); l.m[t] = true; l.mu.Unlock() }
func (l *tunnels) remove(t *tunnel) { l.mu.Lock(); delete(l.m, t); l.mu.Unlock() }
func (l *tunnels) teardownAll() {
	l.mu.Lock()
	defer l.mu.Unlock()
	for t := range l.m {
		t.teardown()
	}
}

// ── admission ────────────────────────────────────────────────────────────

type route struct {
	Dst   string `json:"dst"`
	Dev   string `json:"dev"`
	Type  string `json:"type"`
	Table string `json:"table"`
}

// routeTable is every IPv4 route, all tables. An error (not an empty list)
// when they can't be read: admission then refuses rather than assume none.
func routeTable() ([]route, error) {
	out, err := exec.Command("ip", "-j", "-4", "route", "show", "table", "all").Output()
	if err != nil {
		return nil, fmt.Errorf("can't read the routing table: %v", err)
	}
	var rs []route
	if err := json.Unmarshal(out, &rs); err != nil {
		return nil, fmt.Errorf("can't read the routing table: %v", err)
	}
	return rs, nil
}

// admit validates a SETUP line: one private /24, strictly spelled, that no
// route other than a default one covers. Returns the canonical CIDR.
func admit(line string, routes []route) (string, error) {
	asked, ok := strings.CutPrefix(line, "SETUP ")
	if !ok {
		return "", errors.New("bad request")
	}
	asked = strings.TrimSpace(asked)
	cidr, ok := privateSlash24(asked)
	if !ok {
		if len(asked) > 64 {
			asked = asked[:64]
		}
		return "", fmt.Errorf("cidr %s: not a private /24 network", asked)
	}
	if r := coveringRoute(cidr, routes); r != nil {
		where := r.Dst
		if r.Dev != "" {
			where += " on " + r.Dev
		}
		return "", fmt.Errorf("route taken: %s is already routed to %s", cidr, where)
	}
	return cidr, nil
}

// privateSlash24 accepts "a.b.c.0/24" in 10/8, 172.16/12, 192.168/16 or
// 100.64/10, strictly spelled (no host bits, no leading zeros).
func privateSlash24(s string) (string, bool) {
	ipPart, bits, ok := strings.Cut(s, "/")
	if !ok || bits != "24" {
		return "", false
	}
	ip, ok := parseIPv4(ipPart)
	if !ok || ip&0xff != 0 {
		return "", false
	}
	a, b := ip>>24, ip>>16&0xff
	private := a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) || (a == 100 && b >= 64 && b <= 127)
	if !private {
		return "", false
	}
	return ipString(ip) + "/24", true
}

// coveringRoute is a route (any table, any kind but default) that overlaps
// the /24: one covering it (a LAN, a VPN, another tunnel) or one inside it
// (a host route, a smaller subnet).
func coveringRoute(cidr string, routes []route) *route {
	netw, mask24, _ := parseCIDR(cidr)
	for i := range routes {
		r := &routes[i]
		if r.Dst == "" || r.Dst == "default" || r.Type == "broadcast" || r.Type == "multicast" {
			continue
		}
		d := r.Dst
		if !strings.Contains(d, "/") {
			d += "/32"
		}
		n, m, ok := parseCIDR(d)
		if !ok || m == 0 {
			continue
		}
		if netw&m == n || n&mask24 == netw {
			return r
		}
	}
	return nil
}

// ── the tunnel ───────────────────────────────────────────────────────────

type tunnel struct {
	file  *os.File
	name  string
	cidr  string
	uid   uint32
	table int
	once  sync.Once
}

const (
	tunSetIff = 0x400454ca // TUNSETIFF
	iffTun    = 0x0001
	iffNoPI   = 0x1000
)

func openTun() (*os.File, string, error) {
	fd, err := syscall.Open("/dev/net/tun", syscall.O_RDWR|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, "", fmt.Errorf("tun: %v", err)
	}
	var ifr [40]byte // struct ifreq: name[16], flags u16
	copy(ifr[:], tunPrefix+"%d")
	*(*uint16)(unsafe.Pointer(&ifr[16])) = iffTun | iffNoPI
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), tunSetIff, uintptr(unsafe.Pointer(&ifr[0]))); e != 0 {
		syscall.Close(fd)
		return nil, "", fmt.Errorf("tun: %v", e)
	}
	name := string(ifr[:clen(ifr[:16])])
	return os.NewFile(uintptr(fd), "/dev/net/tun"), name, nil
}

func clen(b []byte) int {
	for i, c := range b {
		if c == 0 {
			return i
		}
	}
	return len(b)
}

func setupTunnel(cidr string, uid uint32) (*tunnel, error) {
	f, name, err := openTun()
	if err != nil {
		return nil, err
	}
	unit, err := strconv.Atoi(strings.TrimPrefix(name, tunPrefix))
	if err != nil || unit < 0 || unit >= 254 {
		f.Close()
		return nil, fmt.Errorf("tun: unexpected name %s", name)
	}
	t := &tunnel{file: f, name: name, cidr: cidr, uid: uid, table: tablBase + unit}
	ok := false
	defer func() {
		if !ok {
			t.teardown()
		}
	}()
	// Before the link is up: nothing arrives on it unguarded.
	sysctl("net/ipv6/conf/"+name+"/disable_ipv6", "1")
	if err := sysctl("net/ipv4/conf/"+name+"/forwarding", "0"); err != nil {
		return nil, fmt.Errorf("forwarding off on %s: %v", name, err)
	}
	// The guests' replies come in from addresses only the caller's uid routes
	// here: with strict reverse-path filtering system-wide the kernel would
	// drop them (the TUN's own setting can't loosen conf/all).
	if b, _ := os.ReadFile("/proc/sys/net/ipv4/conf/all/rp_filter"); strings.TrimSpace(string(b)) == "1" {
		return nil, errors.New("strict reverse-path filtering (net.ipv4.conf.all.rp_filter=1) would drop the tunnel's replies; set it to 2 (loose)")
	}
	sysctl("net/ipv4/conf/"+name+"/rp_filter", "0")
	tbl := strconv.Itoa(t.table)
	steps := [][]string{
		// Ingress: IPv4 from the /24, nothing else.
		{"tc", "qdisc", "add", "dev", name, "ingress"},
		{"tc", "filter", "add", "dev", name, "ingress", "prio", "1", "protocol", "ip", "u32", "match", "ip", "src", cidr, "action", "pass"},
		{"tc", "filter", "add", "dev", name, "ingress", "prio", "2", "protocol", "all", "matchall", "action", "drop"},
		// A link-scope address, never a source for routed traffic: an
		// interface without any is a reverse-path failure for everything
		// arriving on it.
		{"ip", "addr", "add", fmt.Sprintf("169.254.98.%d/32", unit+1), "scope", "link", "dev", name},
		{"ip", "link", "set", "dev", name, "mtu", "1500", "up"},
		{"ip", "route", "add", cidr, "dev", name, "table", tbl},
		{"ip", "rule", "add", "pref", strconv.Itoa(prefRoute), "uidrange", fmt.Sprintf("%d-%d", uid, uid), "lookup", tbl},
	}
	for _, s := range steps {
		if out, err := exec.Command(s[0], s[1:]...).CombinedOutput(); err != nil {
			return nil, fmt.Errorf("%s: %s", strings.Join(s, " "), strings.TrimSpace(string(out)))
		}
	}
	ok = true
	return t, nil
}

// teardown removes the uid rule and the route, and closes our fd.
// Idempotent: a rule already gone is fine.
func (t *tunnel) teardown() {
	t.once.Do(func() {
		tbl := strconv.Itoa(t.table)
		exec.Command("ip", "rule", "del", "pref", strconv.Itoa(prefRoute), "uidrange",
			fmt.Sprintf("%d-%d", t.uid, t.uid), "lookup", tbl).Run()
		exec.Command("ip", "route", "flush", "table", tbl).Run()
		// The TUN goes when its last fd closes (ours here, the caller's
		// when it exits), and its address, filter and route with it.
		t.file.Close()
	})
}

type ipRule struct {
	Priority int    `json:"priority"`
	Table    string `json:"table"`
}

// cleanupStale removes uid rules that outlived their tunnel (a helper killed
// before its teardown): one whose table has no route left — the TUN, and its
// route, went away. (Harmless meanwhile: an empty table falls through.)
func cleanupStale() {
	out, err := exec.Command("ip", "-j", "-4", "rule", "show").Output()
	if err != nil {
		return
	}
	var rules []ipRule
	if json.Unmarshal(out, &rules) != nil {
		return
	}
	for _, r := range rules {
		if r.Priority == prefRoute {
			if n, err := strconv.Atoi(r.Table); err == nil && n >= tablBase && n < tablBase+1000 {
				if rt, _ := exec.Command("ip", "-4", "route", "show", "table", r.Table).Output(); len(strings.TrimSpace(string(rt))) == 0 {
					exec.Command("ip", "rule", "del", "pref", strconv.Itoa(prefRoute), "lookup", r.Table).Run()
				}
			}
		}
	}
}

func sysctl(key, value string) error {
	return os.WriteFile("/proc/sys/"+key, []byte(value), 0)
}
