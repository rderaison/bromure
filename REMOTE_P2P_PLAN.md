# Bromure Agentic Coding — Peer-to-Peer (dual-NAT) Connection Plan

Let two bromure-ac instances connect to each other when **both are behind NAT**,
using a small cloud server to *coordinate* the connection — but **not** to carry
the traffic, except as a last-resort fallback for the NAT combinations nothing
else can beat.

This is a transport substrate underneath the existing fat client
(`REMOTE_FAT_CLIENT_PLAN.md`): it changes *how a dialer reaches a listener*, and
nothing above it. Status: **design only, not implemented.**

---

## The one assumption we're removing

The fat client is already asymmetric and SSH-based:

- The **listener** (authoritative instance, where the VMs live) runs the embedded
  NIOSSH server `RemoteAccessServer`, bound `0.0.0.0:2222`.
- The **dialer** (fat client) runs the system `ssh` binary —
  `SSHTunnel.dial(sshArgs(for: host))` connects to `host.address:host.port`,
  bridges the channel to the remote's `control.sock`, and *everything* rides that
  one transport: the `/state` mirror poll, terminals (`__attach-window`), TCP
  forwards (`forwardDial`), UDP (`forwardDialUDP`), SOCKS, browser-MCP relay.
- Trust is **end-to-end**: SSH host-key TOFU pinning (`RemoteHost.pinnedHostKey`)
  + the dialer's pubkey in the listener's `authorized_keys`.

The *only* thing dual-NAT breaks is one implicit assumption: **the dialer can open
a TCP connection to `host.address:host.port`.** Everything above is
transport-agnostic. So the entire job is:

> **Produce a reachable endpoint for that one connection without touching anything
> above it.** Keep SSH end-to-end. Insert a NAT-traversal broker that presents a
> local loopback endpoint `127.0.0.1:N` on the dialer, moves those bytes
> peer-to-peer to the listener, and splices them into the listener's
> `127.0.0.1:2222` sshd.

Consequences that fall out of this abstraction, and that we design *around*:

- **The cloud server is never trusted with data or identity.** SSH stays E2E, so a
  fully compromised server can deny service or observe metadata (who/when/how
  many bytes) but cannot read the stream or impersonate a peer — it holds no SSH
  host key and no client key. This is a **security invariant**, stated once,
  relied on everywhere below.
- **A punched/mapped port exposed to the internet is safe** *only because* SSH auth
  guards it: a random scanner that reaches it just fails auth.
- `SSHTunnel.dial`, `forwardDial`, `forwardDialUDP`, `browserMCPDial`, the whole
  mirror — **unchanged**. `RemoteHost.address/port` simply becomes `127.0.0.1:N`.

---

## Design decisions (proposed)

- **Reuse the dialer/listener asymmetry per session.** Symmetric software, but for
  each connection one side dials and one side listens (= today's roles). This
  decides *who opens the port*.
- **SSH stays the security & reliability boundary.** The broker only moves opaque
  bytes; it never parses or re-auths them.
- **The server carries data only as a metered fallback.** Direct path is the goal;
  relay is the escape hatch, surfaced in the UI when used.
- **Ship the port-mapping path first, add hole-punching later** (phasing below) —
  matches how the fat client itself was built, and directly realizes the
  "make one end open a port" idea with the smallest surface.

---

## Architecture

```
   Instance A (dialer)                 Cloud server                 Instance B (listener)
   ┌─────────────────┐            (control plane only)             ┌─────────────────┐
   │ fat-client UI   │            ┌───────────────────┐            │ RemoteAccessSrv │
   │  ssh → 127.0.0.1│            │ rendezvous /       │            │   sshd :2222    │
   │        :N       │            │ signaling          │            │        ▲        │
   │      │          │            │ + STUN reflexive   │            │        │        │
   │  ┌───▼────────┐ │◀─outbound─▶│ + TURN (fallback   │◀─outbound─▶│ ┌──────┴─────┐ │
   │  │ p2p broker │ │  ctrl conn │   relay, capped)   │  ctrl conn │ │ p2p broker │ │
   │  └───┬────────┘ │            └───────────────────┘            │ └──────┬─────┘ │
   └──────┼──────────┘                                             └────────┼───────┘
          │                     direct P2P data path                        │
          └────────────────(hole-punched / port-mapped)────────────────────┘
                       (falls back through the server only if this fails)
```

New piece: a **p2p broker** in each instance — a helper process spawned like the
existing `ssh` / `cloudflared` subprocesses, lifecycle-managed exactly like
`RemoteSocksForwarder` / `FatClientTunnel` in `RemoteHostController.start()/stop()`.

Both instances hold a **persistent outbound** control connection to the server
(WebSocket or gRPC over TLS). Outbound is the whole trick: NATs allow outbound
freely, so both peers stay reachable *by the server* without any inbound rule.

### The server's three hats

1. **Rendezvous / signaling** — matches two peers by pairing identity, shuttles
   small control messages between them (candidate lists, "punch now" beacons).
   Bytes, not streams.
2. **STUN** — reflects each peer's observed public `ip:port` back to it. It
   already sees the source of the control connection; nearly free.
3. **TURN (fallback)** — relays the byte stream *only* when the direct path
   fails, only for that session, rate/volume-capped. The one case where traffic
   traverses the server.

Keep it near-stateless: sessions in memory, peers keyed by identity, no data at
rest. A standards-compliant option is **coturn** (STUN+TURN) plus a thin
signaling service; or one small custom service doing all three.

---

## Identity, pairing & trust

- **Pairing**: a shared identity — a one-shot pairing code (like the current
  `FatClientConnect` flow) or an account both sign into. First pairing exchanges
  long-term public keys through the server, confirmed by a short SAS the user
  verifies once (reuse the existing host-key-fingerprint confirmation panel).
- **Trust is independent of the server**: the listener's SSH host key stays pinned
  (`pinnedHostKey`); the dialer's key stays in `authorized_keys`. Compromised
  server ⇒ metadata only. (Invariant, above.)
- The broker authenticates *to the server* with a per-instance token so signaling
  is only relayed between paired peers.

---

## Connection establishment: the candidate ladder

ICE (RFC 8445) in spirit. Each side gathers candidates, they exchange them via
the server, and try them best-first. **Port mapping is one rung, not the whole
ladder** — it fails outright under carrier-grade NAT, so it can never be the only
mechanism.

**Rung 1 — Local / LAN.** Same network (or reachable LAN IP) ⇒ connect directly.
Free; common in offices.

**Rung 2 — Explicit port mapping on the *listener* (the "open a port" idea).** The
server designates the listener as the mapper. Its broker asks the home router for
an external port, in descending capability:

- **PCP** (RFC 6887) — most capable, supersedes NAT-PMP; UDP `:5351` to gateway.
- **NAT-PMP** (RFC 6886) — Apple's, same port, older routers.
- **UPnP-IGD** — SSDP multicast discovery + SOAP; oldest/widest, flakiest.

On success: a stable public `ip:port`. The listener advertises it; the dialer
connects **straight there**. For a **TCP** map this is the zero-shim case — the
dialer's `ssh` connects with no new transport code at all (`RemoteHost` =
public endpoint). **Critical caveat we design around:** a port map only pierces
the *first* NAT hop. Behind CGNAT the mapped address is still private upstream and
unreachable — so we **verify reachability** (dialer actually connects / the port
is probed) instead of trusting the mapping. Renew before lease expiry; **tear the
mapping down at session end** so we don't leave holes open.

**Rung 3 — UDP hole punching.** Neither side can map: both learn each other's
server-reflexive candidates (STUN), and on a time-synchronized "go" beacon from
the server, both send toward the other's public `ip:port` simultaneously. Each
side's outbound packet opens its own NAT's return pinhole, so the peer's inbound
packet is accepted. Works for full-cone / (port-)restricted-cone NATs — the
majority. **Fails symmetric×symmetric** (each NAT picks a fresh external port per
destination, so the STUN-seen port ≠ the peer-to-peer port; port prediction is
unreliable). We surface this honestly rather than spin.

**Rung 4 — TURN relay (fallback).** Symmetric×symmetric or hostile firewalls:
relay through the server. Always works, rarely used, capped. The only "traffic
through the server" case.

The server orchestrates timing and picks a winner, but **candidate validation is
end-to-end** — a path only succeeds if SSH auth + host-key pinning succeed — so an
injected/bogus candidate can at most waste an attempt (bound the attempt count),
never redirect us to an attacker.

---

## Transport / reliability over the negotiated path

SSH needs a **reliable, ordered byte stream**; hole punching yields a **UDP**
flow. Two compositions:

**Option A — ICE path + QUIC (recommended for full coverage).** Use ICE only to
*discover and open the UDP path* (rungs 1–4, incl. TURN), then run **QUIC** over
that flow: reliable, multiplexed, encrypted, path-migration-capable. Splice SSH
inside one QUIC stream. (WebRTC's model, QUIC replacing DTLS/SCTP.) The broker
exposes `127.0.0.1:N` on the dialer, forwards to `127.0.0.1:2222` on the listener.
Uniform across all four rungs.

**Option B — port-mapped / relayed TCP, no hole punching (simplest; implements the
idea directly).** Listener maps a **TCP** port (rung 2); dialer's `ssh` connects
to the public endpoint with **zero new transport code**. If mapping fails or CGNAT
is detected, fall back to a **TCP relay** through the server (rung 4). No ICE, no
QUIC. Gives up direct connectivity only when *neither* side can map a port —
covered by relay.

**Recommendation: ship B, evolve to A.** B matches the fat client's phased,
`ssh`-unchanged style and directly realizes "make one end open a port"; most home
routers support PCP/NAT-PMP/UPnP, so B alone gets direct connectivity in the
common case. Add rung 3 + QUIC later to shrink relay to the symmetric tail.

---

## Build vs. adopt

bromure-ac already shells out to helper binaries (`ssh`, `cloudflared`), so a
broker helper is idiomatic.

- **Port mapping (rung 2)** — write natively; PCP/NAT-PMP are compact binary
  protocols, UPnP is SSDP+SOAP. A few hundred lines in the broker.
- **ICE + hole punch + TURN (rungs 3–4, Option A)** — **adopt**, don't build.
  **libjuice** (C, MIT, tiny, full ICE/STUN/TURN, easy to wrap from Swift) or
  **pion** (Go WebRTC → a helper binary presenting the loopback shim). This is the
  Tailscale `disco`+DERP / WebRTC-data-channel problem; don't re-derive it.
- **Server** — coturn (STUN+TURN) + thin signaling, or one small custom service.

---

## The broker's loopback-shim interface

The broker is one helper process per instance, driven by the app over a local
control channel (AF_UNIX JSON, like the other helpers). It hides *all* path
selection behind a single promise: **"give me a peer, I hand you a
`127.0.0.1:port`."**

### App ⇄ broker control (local, per request)

```
// Dialer side — app asks the broker to make a peer reachable.
→ { "op": "open",   "peer": "<peerID>", "role": "dialer" }
← { "ok": true, "endpoint": "127.0.0.1:49xxx", "path": "port-mapped|holepunch|lan|relay" }
   // app then points RemoteHost.address/port at endpoint; ssh dials it unchanged.

// Listener side — app tells the broker where local SSH lives.
→ { "op": "listen", "peer": "<peerID>", "role": "listener", "sshPort": 2222 }
← { "ok": true }                       // broker now accepts inbound sessions for peer,
                                        // splicing each to 127.0.0.1:2222.

→ { "op": "status", "peer": "<peerID>" }
← { "path": "holepunch", "rttMs": 34, "relayed": false, "bytesUp": …, "bytesDown": … }

→ { "op": "close",  "peer": "<peerID>" }   // drops the path, tears down any port map.

// Unsolicited:
← { "event": "path-changed", "peer": "…", "path": "relay",   "reason": "holepunch-timeout" }
← { "event": "quality",      "peer": "…", "path": "port-mapped", "rttMs": 12 }
```

`endpoint` is always loopback, so **nothing above SSH ever learns which rung
won.** `path`/`quality` feed a connection-quality pill
(`Direct (LAN) / Direct (port-mapped) / Direct (hole-punched) / Relayed`) reusing
the existing toolbar network-state pattern.

### Broker ⇄ server signaling (the wire)

Small JSON control messages, one persistent outbound connection per instance:

```
→ register   { "instanceID": "…", "token": "…", "pubkey": "<ssh-ed25519 …>" }
→ offer      { "session": "…", "to": "<peerID>", "candidates": [ Candidate, … ] }
← answer     { "session": "…", "from": "<peerID>", "candidates": [ Candidate, … ] }
↔ punch      { "session": "…", "at": <server-clock-ms> }   // synchronized "go" beacon
↔ relay-open { "session": "…" }                             // request TURN allocation
← error      { "session": "…", "code": "peer-offline|unpaired|relay-cap" }

Candidate = {
  "kind":  "host" | "srflx" | "port-mapped" | "relay",
  "proto": "udp" | "tcp",
  "ip": "…", "port": <int>,
  "prio": <int>,          // ICE-style preference; try highest first
  "ttl": <int>            // for port-mapped: lease seconds; broker renews at ttl/2
}
```

Notes that matter:

- **`session`** namespaces a single connection attempt so retries/relays don't
  cross-talk; the server holds only in-memory session state.
- **`punch.at`** is a *server* timestamp both brokers convert to their local
  clock via the control connection's RTT — hole punching needs the two sends
  within ~tens of ms.
- The server **never** sees SSH bytes; even on `relay`, it forwards opaque frames
  between the two TURN legs.
- **Candidate validation is local**: the dialer tries candidates by `prio`; a
  candidate is "good" only once SSH completes host-key + pubkey auth over it.

### Listener splice & the `EHOSTUNREACH` gotcha

On the listener, the broker splices each accepted P2P session into
`127.0.0.1:2222` — the embedded sshd, already bound `0.0.0.0:2222`. This is safe:
the Phase-4 finding (`FatClientForward`) that the bromure-ac process can't TCP to
its *own guest* IPs is about **VM guest** addresses, not loopback. Loopback sshd
is reachable from the app's process tree, so no vsock detour is needed here.

---

## Integration touchpoints (nothing above the transport changes)

- `RemoteHost` gains `connection: .direct(address, port) | .peer(peerID)`.
  `.peer` resolves through the broker (`op:open`) to a live `127.0.0.1:N`.
- `RemoteTransport.sshArgs` / `SSHTunnel.dial` point at that loopback endpoint —
  otherwise **unchanged**. `forwardDial`, `forwardDialUDP`, `browserMCPDial`
  inherit it for free.
- `RemoteAccessServer` already binds `2222`; add a broker `op:listen` that splices
  inbound P2P sessions into `127.0.0.1:2222`.
- Broker lifecycle mirrors `RemoteSocksForwarder` / `FatClientTunnel` in
  `RemoteHostController.start()/stop()`.
- Connect UX extends `FatClientConnect`: enter/scan a pairing code instead of
  `address:port`; reuse the fingerprint-confirmation panel for the one-time SAS.

---

## Security & failure modes

- **Server untrusted for data & identity** — SSH E2E preserves confidentiality and
  peer authenticity; server sees metadata only. (Invariant.)
- **Exposed mapped/punched ports are safe** only because SSH auth guards them;
  never expose the control socket directly. Short mapping leases + renewal +
  teardown at session end.
- **Malicious candidate injection** can't redirect (E2E auth validates the
  endpoint), only waste attempts — bound the attempt count.
- **Relay abuse / cost** — TURN rate/volume-capped per session; UI shows when a
  session is relayed.
- **UX honesty** — connection-quality pill; under CGNAT-both-ends, say "Relayed"
  plainly rather than pretend.

---

## Phasing

1. **Rendezvous + STUN + port mapping (rung 2) + TCP relay fallback (rung 4)** —
   Option B. Directly implements the idea, reuses `ssh` unchanged, smallest
   surface, covers most home routers.
2. **UDP hole punching (rung 3) + QUIC transport** — Option A via libjuice/pion.
   Shrinks relay to the symmetric×symmetric tail.
3. **Pairing/identity polish** — accounts or durable pairing codes, multi-peer
   fleet (ties into `FatClientFleet`), connection-quality UI.

---

## Open questions

- **Pairing model** — one-shot codes (like the current connect flow) vs. a
  signed-in account directory? Sets the server's statefulness.
- **Who runs the relay** — the existing cloud box as coturn, or managed TURN?
  Sets the cost/scaling ceiling.
- **v1 coverage target** — is "direct whenever ≥1 side can map a port, else relay"
  (Option B) acceptable for v1, or must hole-punching land in v1 to minimize
  relay from day one?
