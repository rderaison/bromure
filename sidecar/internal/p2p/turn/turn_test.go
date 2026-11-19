package turn

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"io"
	"math/big"
	"net"
	"reflect"
	"strconv"
	"testing"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/p2p/stun"
	"github.com/rderaison/bromure/sidecar/internal/p2p/turn/turntest"
)

const tUser, tPass = "1700000000:conn-1", "s3cret-pass"

func allowAll(string) bool { return true }

func attrTypes(m *stun.Message) []uint16 {
	var out []uint16
	for _, a := range m.Attrs {
		out = append(out, a.Type)
	}
	return out
}

// The long-term dance against the fake relay: 401 → signed retry, a 438
// rotates the nonce, and the attributes go in transact's order.
func TestClientAuthDance(t *testing.T) {
	srv, err := turntest.Start(tUser, tPass)
	if err != nil {
		t.Fatal(err)
	}
	defer srv.Close()
	srv.StaleNonceOnce = true
	c := NewClient(srv.Host, srv.Port, false, tUser, tPass)
	if err := c.Connect(2 * time.Second); err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	a, err := c.AllocateTCP(3 * time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if a.RelayIP != "127.0.0.1" || a.RelayPort == 0 || a.MappedIP != "127.0.0.1" || a.Lifetime != 600 {
		t.Fatalf("allocation %+v", a)
	}
	if !c.CreatePermission("198.51.100.20", 2*time.Second) {
		t.Fatal("permission")
	}
	if life, ok := c.Refresh(2 * time.Second); !ok || life != 600 {
		t.Fatalf("refresh %d %v", life, ok)
	}
	reqs := srv.Requests()
	var types []uint16
	for _, r := range reqs {
		types = append(types, r.Type)
	}
	want := []uint16{stun.AllocateRequest, stun.AllocateRequest, stun.AllocateRequest, stun.CreatePermissionRequest, stun.RefreshRequest}
	if !reflect.DeepEqual(types, want) {
		t.Fatalf("requests %x want %x", types, want)
	}
	if got := attrTypes(reqs[0]); !reflect.DeepEqual(got, []uint16{stun.AttrRequestedTransport}) {
		t.Fatalf("first allocate attrs %x", got)
	}
	signed := []uint16{stun.AttrRequestedTransport, stun.AttrUsername, stun.AttrRealm, stun.AttrNonce, stun.AttrMessageIntegrity}
	if got := attrTypes(reqs[1]); !reflect.DeepEqual(got, signed) {
		t.Fatalf("signed allocate attrs %x", got)
	}
	if n, _ := reqs[2].String(stun.AttrNonce); n != "nonce-2" {
		t.Fatalf("438 didn't rotate the nonce: %q", n)
	}
	if got := attrTypes(reqs[4]); !reflect.DeepEqual(got, []uint16{stun.AttrUsername, stun.AttrRealm, stun.AttrNonce, stun.AttrMessageIntegrity}) {
		t.Fatalf("refresh attrs %x", got)
	}
}

func TestWrongPassword(t *testing.T) {
	srv, _ := turntest.Start(tUser, tPass)
	defer srv.Close()
	c := NewClient(srv.Host, srv.Port, false, tUser, "wrong")
	_ = c.Connect(2 * time.Second)
	defer c.Close()
	if _, err := c.AllocateTCP(2 * time.Second); err == nil {
		t.Fatal("allocated with a wrong password")
	}
}

func TestPublicAddressTCP(t *testing.T) {
	srv, _ := turntest.Start(tUser, tPass)
	defer srv.Close()
	ip, port, ok := PublicAddress(srv.Host, srv.Port, 2*time.Second)
	if !ok || ip != "127.0.0.1" || port == 0 {
		t.Fatalf("%s:%d %v", ip, port, ok)
	}
}

func echoServer(t *testing.T) int {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() { io.Copy(c, c); c.Close() }()
		}
	}()
	return ln.Addr().(*net.TCPAddr).Port
}

func roundTrip(t *testing.T, relay string) {
	t.Helper()
	peer, err := net.DialTimeout("tcp", relay, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer peer.Close()
	peer.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := peer.Write([]byte("SSH-2.0-test\r\n")); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 14)
	if _, err := io.ReadFull(peer, buf); err != nil || string(buf) != "SSH-2.0-test\r\n" {
		t.Fatalf("echo %q %v", buf, err)
	}
}

// End to end: a peer connecting to the relayed address becomes a
// ConnectionAttempt, the listener binds a data connection and splices it to
// the local "SSH server" (an echo here).
func TestListenerSplicesConnectionAttempt(t *testing.T) {
	srv, _ := turntest.Start(tUser, tPass)
	defer srv.Close()
	sshPort := echoServer(t)
	l, st, err := StartListener(Credentials{srv.URLs(), tUser, tPass}, []string{"127.0.0.1"}, sshPort, allowAll)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Stop()
	if st.Relay.Kind != "relay" || st.Relay.Proto != "tcp" || st.Relay.Prio != 256 || st.Relay.TTL == nil || *st.Relay.TTL != 600 {
		t.Fatalf("relay candidate %+v", st.Relay)
	}
	relay := net.JoinHostPort(st.Relay.IP, strconv.Itoa(st.Relay.Port))
	roundTrip(t, relay)
	roundTrip(t, relay) // a second SSH connection gets its own leg
	var binds int
	for _, r := range srv.Requests() {
		if r.Type == stun.ConnectionBindRequest {
			binds++
			if got := attrTypes(r); !reflect.DeepEqual(got, []uint16{stun.AttrConnectionID, stun.AttrUsername, stun.AttrRealm, stun.AttrNonce, stun.AttrMessageIntegrity}) {
				t.Fatalf("bind attrs %x", got)
			}
		}
	}
	if binds != 2 {
		t.Fatalf("%d ConnectionBinds", binds)
	}
}

func TestListenerRefusesPrivatePeers(t *testing.T) {
	if _, _, err := StartListener(Credentials{[]string{"turn:127.0.0.1:1?transport=tcp"}, tUser, tPass}, []string{"10.0.0.1", "127.0.0.1"}, 1, nil); err == nil {
		t.Fatal("allocated for private peers")
	}
}

func selfSigned(t *testing.T) (*tls.Config, *x509.CertPool) {
	k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tmpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "relay.test"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		IPAddresses: []net.IP{net.ParseIP("127.0.0.1")}, KeyUsage: x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &k.PublicKey, k)
	if err != nil {
		t.Fatal(err)
	}
	cert, _ := x509.ParseCertificate(der)
	pool := x509.NewCertPool()
	pool.AddCert(cert)
	return &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: k}}}, pool
}

func TestListenerOverTLS(t *testing.T) {
	cfg, pool := selfSigned(t)
	srv, err := turntest.StartTLS(tUser, tPass, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer srv.Close()
	TLSConfig = &tls.Config{RootCAs: pool}
	defer func() { TLSConfig = nil }()
	sshPort := echoServer(t)
	// turns: preferred over the turn: entry listed first.
	urls := append([]string{"turn:127.0.0.1:1?transport=tcp"}, srv.URLs()...)
	l, st, err := StartListener(Credentials{urls, tUser, tPass}, []string{"127.0.0.1"}, sshPort, allowAll)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Stop()
	if !l.client.TLS {
		t.Fatal("didn't use TLS")
	}
	roundTrip(t, net.JoinHostPort(st.Relay.IP, strconv.Itoa(st.Relay.Port)))
}

func TestTLSFallsBackToTCP(t *testing.T) {
	srv, _ := turntest.Start(tUser, tPass)
	defer srv.Close()
	dead, _ := net.Listen("tcp", "127.0.0.1:0")
	deadPort := dead.Addr().(*net.TCPAddr).Port
	dead.Close()
	urls := []string{"turns:127.0.0.1:" + strconv.Itoa(deadPort) + "?transport=tcp", srv.URLs()[0]}
	l, _, err := StartListener(Credentials{urls, tUser, tPass}, []string{"127.0.0.1"}, echoServer(t), allowAll)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Stop()
	if l.client.TLS || l.client.Port != srv.Port {
		t.Fatalf("fallback went to %s:%d tls=%v", l.client.Host, l.client.Port, l.client.TLS)
	}
}

func TestURLHelpers(t *testing.T) {
	urls := []string{
		"stun:fra.turn.example:3478",
		"turn:fra.turn.example:3478?transport=udp",
		"turn:fra.turn.example:3478?transport=tcp",
		"turns:fra.turn.example:5349?transport=tcp",
		"turn:nyc.turn.example?transport=tcp",
	}
	if e, ok := PreferredRelayEndpoint(urls); !ok || e != (Endpoint{"fra.turn.example", 5349, true}) {
		t.Fatalf("relay endpoint %+v", e)
	}
	if e, ok := PreferredRelayEndpoint(urls[:3]); !ok || e != (Endpoint{"fra.turn.example", 3478, false}) {
		t.Fatalf("tcp fallback %+v", e)
	}
	if got := DistinctHosts(urls); !reflect.DeepEqual(got, []string{"fra.turn.example", "nyc.turn.example"}) {
		t.Fatalf("hosts %v", got)
	}
	st := StunEndpointsPerHost(urls)
	if len(st) != 2 || st[0].Port != 3478 || st[0].Transport != "" || st[1] != (HostPort{"nyc.turn.example", 3478, "tcp"}) {
		t.Fatalf("stun endpoints %+v", st)
	}
	old := ProbeRTT
	defer func() { ProbeRTT = old }()
	ProbeRTT = func(host string, port int, _ time.Duration) (time.Duration, bool) {
		if host == "nyc.turn.example" && port == 3478 {
			return 5 * time.Millisecond, true
		}
		if host == "fra.turn.example" && port == 5349 {
			return 80 * time.Millisecond, true
		}
		return 0, false
	}
	got := OrderURLsByRTT(urls, 3, 200*time.Millisecond)
	if got[0] != "turn:nyc.turn.example?transport=tcp" || len(got) != len(urls) {
		t.Fatalf("rtt order %v", got)
	}
}

func TestRelayPermits(t *testing.T) {
	for ip, want := range map[string]bool{
		"8.8.8.8": true, "10.1.2.3": false, "100.64.0.1": false, "127.0.0.1": false, "169.254.1.1": false,
		"172.16.5.5": false, "192.0.2.1": false, "192.168.1.1": false, "198.18.0.1": false, "198.51.100.1": false,
		"203.0.113.1": false, "224.0.0.1": false, "240.0.0.1": false, "2606:4700::1": true, "2001:db8::1": false,
		"fe80::1": false, "::ffff:8.8.8.8": false, "host.example": false,
	} {
		if IsPublicUnicast(ip) != want {
			t.Errorf("IsPublicUnicast(%s) != %v", ip, want)
		}
	}
	p := NewRelayPermits([]string{"8.8.8.8"}, []string{"1.1.1.1"}, nil)
	if !p.Add("9.9.9.9") || !p.Add("8.8.4.4") || p.Add("4.4.4.4") || p.Add("10.0.0.1") {
		t.Fatal("cap / admit")
	}
	ip, tries, _ := p.TakeOne()
	if ip != "1.1.1.1" || tries != 0 || !p.Record(ip, tries, false) {
		t.Fatal("retry queued")
	}
	for i := 1; i < MaxTries; i++ {
		ip, tries, _ = p.TakeOne()
		for ip != "1.1.1.1" {
			p.Record(ip, tries, true)
			ip, tries, _ = p.TakeOne()
		}
		again := p.Record(ip, tries, false)
		if again != (i < MaxTries-1) {
			t.Fatalf("try %d again=%v", i, again)
		}
	}
	if got := Admissible([]string{"8.8.8.8", "8.8.8.8", "10.0.0.1", "1.1.1.1", "2.2.2.2", "3.3.3.3", "4.4.4.4"}, nil); len(got) != MaxAddresses {
		t.Fatalf("admissible %v", got)
	}
}

func TestParseHostPort(t *testing.T) {
	cases := map[string]HostPort{
		"turn:relay.example:3478?transport=tcp":      {"relay.example", 3478, "tcp"},
		"turns:relay.example:5349?transport=tcp&x=1": {"relay.example", 5349, "tcp"},
		"stun:relay.example":                         {"relay.example", 3478, ""},
	}
	for in, want := range cases {
		if got, ok := ParseHostPort(in); !ok || got != want {
			t.Errorf("%s -> %+v", in, got)
		}
	}
	if _, ok := ParseHostPort("nocolon"); ok {
		t.Error("accepted")
	}
}
