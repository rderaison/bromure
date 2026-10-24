package netmon

import (
	"strings"
	"testing"
	"time"
)

func TestSignature(t *testing.T) {
	a := Signature(true, []string{"en0", "en1", "en0"}, []string{"en1=10.0.0.2", "en0=192.168.1.20"})
	if a != "satisfied|en0,en1|en0=192.168.1.20,en1=10.0.0.2" {
		t.Fatal(a)
	}
	if Signature(true, []string{"en1", "en0"}, []string{"en0=192.168.1.20", "en1=10.0.0.2"}) != a {
		t.Fatal("order matters")
	}
	if Signature(true, []string{"en0"}, []string{"en0=192.168.7.7"}) == Signature(true, []string{"en0"}, []string{"en0=192.168.1.20"}) {
		t.Fatal("another network on the same adapter must differ")
	}
	for _, n := range []string{"utun3", "vEthernet (WSL)", "docker0", "Tailscale", "bridge100", "VirtualBox Host-Only Network", "awdl0", "lo0"} {
		if !isVirtual(n) {
			t.Errorf("%s not filtered", n)
		}
	}
	for _, n := range []string{"en0", "Wi-Fi", "Ethernet", "eth0", "wlan0"} {
		if isVirtual(n) {
			t.Errorf("%s filtered", n)
		}
	}
}

func TestMonitorEmits(t *testing.T) {
	got := make(chan Update, 4)
	m := &Monitor{Handler: func(u Update) { got <- u }, PollEvery: time.Hour}
	m.Start()
	defer m.Stop()
	select {
	case u := <-got:
		if !strings.HasPrefix(u.Signature, "satisfied|") && !strings.HasPrefix(u.Signature, "unsatisfied|") {
			t.Fatalf("signature %q", u.Signature)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("no baseline")
	}
	m.Kick()
	select {
	case <-got:
	case <-time.After(3 * time.Second):
		t.Fatal("kick didn't recompute")
	}
}
