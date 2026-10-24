package account

import (
	"errors"
	"net/url"
	"os"
	"reflect"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/p2p/cptest"
	"github.com/rderaison/bromure/sidecar/internal/p2p/identity"
	"github.com/rderaison/bromure/sidecar/internal/settings"
)

const (
	clientLine = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIClientKeyBlobForTestsOnly you@example.com"
	serverKey  = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIServerKeyBlobForTestsOnly bromure-ac"
)

type keySink struct {
	mu     sync.Mutex
	calls  int
	marker string
	lines  []string
}

func (k *keySink) set(marker string, lines []string) {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.calls++
	k.marker, k.lines = marker, append([]string(nil), lines...)
}

func (k *keySink) get() (int, string, []string) {
	k.mu.Lock()
	defer k.mu.Unlock()
	return k.calls, k.marker, append([]string(nil), k.lines...)
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	for end := time.Now().Add(8 * time.Second); time.Now().Before(end); time.Sleep(25 * time.Millisecond) {
		if cond() {
			return
		}
	}
	t.Fatalf("timed out waiting for %s", what)
}

func TestSignInSyncSignOut(t *testing.T) {
	settings.ResetForTest()
	cp := cptest.New()
	defer cp.Close()
	cp.AddDevice(&cptest.Device{ID: "dev-server", Token: "tok-server", Name: "Your Mac", Capability: "server",
		SSHKey: serverKey, SSHUsername: "you", ForceOnline: true})
	cp.AddDevice(&cptest.Device{ID: "dev-offline", Token: "tok-off", Name: "Old Mac", Capability: "server"})
	cp.AddDevice(&cptest.Device{ID: "dev-sidecar", Token: "tok-sc", Name: "Other PC", Capability: "agent-host", ForceOnline: true})

	var opened string
	keys := &keySink{}
	a := New(Config{SSHPort: 1, MachineName: func() string { return "Your PC" }, UserName: "you",
		ClientPublicKey: func() (string, error) { return clientLine, nil },
		SetManagedKeys:  keys.set,
		OpenURL:         func(u string) error { opened = u; return nil }})
	defer a.Close()

	u, err := a.BeginSignIn()
	if err != nil || u != opened {
		t.Fatalf("begin %q %v (opened %q)", u, err, opened)
	}
	pu, _ := url.Parse(u)
	state := pu.Query().Get("state")
	if pu.Scheme+"://"+pu.Host+pu.Path != EnrollURL || pu.Query().Get("capability") != "agent-host" ||
		pu.Query().Get("app") != "agent-host" || len(state) != 36 || pu.RawQuery != "capability=agent-host&state="+state+"&app=agent-host" {
		t.Fatalf("enroll url %s", u)
	}
	if b, _ := os.ReadFile(PendingStateFile()); string(b) != state {
		t.Fatalf("pending state %q", b)
	}

	api := url.QueryEscape(cp.URL)
	if err := a.Complete("bromure-agent-host://enroll?code=CODE-FROM-BROWSER&state=SOMEONE-ELSE&api=" + api); !errors.Is(err, ErrNotOurs) {
		t.Fatalf("foreign state: %v", err)
	}
	if err := a.Complete("not a link"); !errors.Is(err, ErrNotALink) || a.Status().LastError == "" {
		t.Fatalf("bad link: %v", err)
	}
	if err := a.Complete("bromure-agent-host://enroll?code=CODE-FROM-BROWSER&state=" + state + "&api=" + api); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(PendingStateFile()); !os.IsNotExist(err) {
		t.Fatal("pending state kept")
	}
	st := a.Status()
	if !st.SignedIn || st.Capability != "agent-host" || st.DeviceName != "Your PC" || st.LastError != "" || !strings.HasPrefix(st.DeviceID, "dev-enrolled-") {
		t.Fatalf("status %+v", st)
	}
	me := cp.Device(st.DeviceID)

	// Key sync: our client key goes up with the agent-host comment and the
	// bare login; the account's keys come down as managed lines.
	waitFor(t, "key sync", func() bool { n, _, _ := keys.get(); return n > 0 })
	if me.SSHKey != "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIClientKeyBlobForTestsOnly bromure-agent-host" || me.SSHUsername != "you" {
		t.Fatalf("published %q as %q", me.SSHKey, me.SSHUsername)
	}
	if got := settings.String("p2p.published", ""); got != st.DeviceID+" you "+me.SSHKey {
		t.Fatalf("published marker %q", got)
	}
	_, marker, lines := keys.get()
	sort.Strings(lines)
	want := []string{
		"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIClientKeyBlobForTestsOnly bromure-account:machine:" + st.DeviceID,
		"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIServerKeyBlobForTestsOnly bromure-account:dev-server",
	}
	if marker != AccountKeyMarker || !reflect.DeepEqual(lines, want) {
		t.Fatalf("managed %q %v", marker, lines)
	}
	waitFor(t, "servers", func() bool { return len(a.Servers()) > 0 })
	if s := a.Servers(); len(s) != 1 || s[0].ID != "dev-server" || s[0].Name != "Your Mac" || s[0].SSHUsername != "you" {
		t.Fatalf("servers %+v", s)
	}
	waitFor(t, "serving", func() bool { return cp.Online(st.DeviceID) && me.Server })

	a.SignOut()
	if _, res := identity.Load(); res != identity.NotEnrolled {
		t.Fatal("record kept")
	}
	if settings.Has("p2p.published") || len(a.Servers()) != 0 {
		t.Fatal("published marker / servers kept")
	}
	if _, _, lines := keys.get(); len(lines) != 0 {
		t.Fatalf("managed keys kept: %v", lines)
	}
	if a.Status().SignedIn {
		t.Fatal("still signed in")
	}
}

// A device enrolled without the agent-host capability publishes nothing.
func TestNotAgentHostPublishesNothing(t *testing.T) {
	settings.ResetForTest()
	cp := cptest.New()
	defer cp.Close()
	cp.EnrollCapability = "client"
	keys := &keySink{}
	a := New(Config{SSHPort: 1, UserName: "you", ClientPublicKey: func() (string, error) { return clientLine, nil },
		SetManagedKeys: keys.set})
	defer a.Close()
	defer identity.Erase()
	if err := a.Complete("bromure://enroll?code=PASTED-CODE-0001&api=" + url.QueryEscape(cp.URL)); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "lastError", func() bool { return strings.Contains(a.Status().LastError, "agent-host capability") })
	if n, _, _ := keys.get(); n != 0 {
		t.Fatal("managed keys set")
	}
	if d := cp.Device(a.Status().DeviceID); d == nil || d.SSHKey != "" {
		t.Fatal("published a key")
	}
}

func TestHelpers(t *testing.T) {
	if l, ok := ClientKeyLine("ssh-ed25519  AAAAblob  some comment"); !ok || l != "ssh-ed25519 AAAAblob bromure-agent-host" {
		t.Fatalf("%q", l)
	}
	if _, ok := ClientKeyLine("ssh-ed25519"); ok {
		t.Fatal("accepted")
	}
}
