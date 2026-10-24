package signal

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func lines(t *testing.T, name string) map[string]string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]string{}
	for _, l := range strings.Split(string(data), "\n") {
		l = strings.TrimRight(l, "\r")
		if l == "" || strings.HasPrefix(l, "#") {
			continue
		}
		k, v, _ := strings.Cut(l, "\t")
		out[k] = v
	}
	return out
}

func TestGoldenOutgoing(t *testing.T) {
	want := lines(t, "outgoing.txt")
	ttl := 600
	cases := map[string]OutgoingFrame{
		"offer":             {"conn-1", 1, KindOffer, WithNote("connect")},
		"answer_relay_only": {"conn-1", 1, KindAnswer, WithCandidates(nil)},
		"srflx_trickle":     {"conn-1", 2, KindCandidate, WithCandidate(NewCandidate(KindSrflx, ProtoTCP, "198.51.100.20", 61000, nil))},
		"relay_trickle":     {"conn-1", 2, KindCandidate, WithCandidate(NewCandidate(KindRelay, ProtoTCP, "203.0.113.50", 49152, &ttl))},
		"host_bundle_v6": {"conn-1", 1, KindAnswer, WithCandidates([]Candidate{
			NewCandidate(KindHost, ProtoTCP, "2001:db8::5", 2223, nil)})},
	}
	for name, f := range cases {
		got, err := f.Encode()
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != want[name] {
			t.Errorf("%s:\n got %s\nwant %s", name, got, want[name])
		}
		// And it parses back to the same frame.
		var back OutgoingFrame
		if err := json.Unmarshal(got, &back); err != nil {
			t.Fatal(err)
		}
		again, _ := back.Encode()
		if string(again) != string(got) {
			t.Errorf("%s: round trip %s", name, again)
		}
	}
}

func TestPriorities(t *testing.T) {
	for _, c := range []struct {
		kind, proto, ip string
		want            int
	}{
		{KindHost, ProtoTCP, "192.168.1.2", 126<<16 | 2<<8},
		{KindPortMapped, ProtoTCP, "198.51.100.1", 110<<16 | 2<<8},
		{KindSrflx, ProtoTCP, "198.51.100.1", 100<<16 | 2<<8},
		{KindRelay, ProtoUDP, "198.51.100.1", 2 << 8},
		{KindRelay, ProtoTCP, "2001:db8::1", 1<<8 | 1<<4},
	} {
		if got := DefaultPriority(c.kind, c.proto, c.ip); got != c.want {
			t.Errorf("%s/%s/%s = %d, want %d", c.kind, c.proto, c.ip, got, c.want)
		}
	}
}

func TestFrameTooLarge(t *testing.T) {
	var cs []Candidate
	for i := 0; i < 60; i++ {
		cs = append(cs, NewCandidate(KindHost, ProtoTCP, "192.168.100.100", 2223, nil))
	}
	_, err := OutgoingFrame{"conn-1", 1, KindAnswer, WithCandidates(cs)}.Encode()
	if _, ok := err.(ErrFrameTooLarge); !ok {
		t.Fatalf("err = %v", err)
	}
}

func TestGoldenIncoming(t *testing.T) {
	in := lines(t, "incoming.txt")
	f, ok := DecodeIncoming([]byte(in["signal"]))
	if !ok || f.Type != FrameSignal || f.ConnectionID != "conn-1" || f.Seq != 3 || f.Kind != KindCandidate || f.From != "c2lnbmFsLWlkLTE2Ynl0" {
		t.Fatalf("signal: %+v", f)
	}
	all := f.Payload.All()
	if len(all) != 1 || all[0].Kind != KindRelay || all[0].Port != 49152 || all[0].TTL == nil || *all[0].TTL != 600 {
		t.Fatalf("signal payload: %+v", all)
	}
	// A bare string payload decodes to an empty payload, not a failure.
	f, _ = DecodeIncoming([]byte(in["signal_bad_payload"]))
	if f.Type != FrameSignal || len(f.Payload.All()) != 0 || f.Payload.V != 1 {
		t.Fatalf("bad payload: %+v", f)
	}
	if f, _ = DecodeIncoming([]byte(in["signal_bad_kind"])); f.Type != "unknown" {
		t.Fatalf("bad kind: %+v", f)
	}
	f, _ = DecodeIncoming([]byte(in["connection"]))
	if f.Type != FrameConnection || f.Grant.ID != "conn-1" || f.Grant.Self.Role != "server" || f.Grant.Peer.DeviceID != "dev-client" {
		t.Fatalf("connection: %+v", f)
	}
	if f, _ = DecodeIncoming([]byte(in["connection_incomplete"])); f.Type != "unknown" {
		t.Fatalf("incomplete grant: %+v", f)
	}
	if f, _ = DecodeIncoming([]byte(in["error"])); f.Type != FrameError || f.ErrorCode != "stale_seq" || f.ConnectionID != "conn-1" {
		t.Fatalf("error: %+v", f)
	}
	if f, _ = DecodeIncoming([]byte(in["error_nocode"])); f.ErrorCode != "unknown" || f.HasConnID {
		t.Fatalf("error_nocode: %+v", f)
	}
	if f, _ = DecodeIncoming([]byte(in["keys_changed"])); f.Type != FrameKeysChanged {
		t.Fatalf("keys: %+v", f)
	}
	if f, ok = DecodeIncoming([]byte(in["future"])); !ok || f.Type != "unknown" || f.RawType != "presence" {
		t.Fatalf("future: %+v", f)
	}
	if _, ok = DecodeIncoming([]byte(`[1,2]`)); ok {
		t.Fatal("array accepted")
	}
}
