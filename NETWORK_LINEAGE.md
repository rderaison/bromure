# Network lineage: from the agent's reasoning to the packet

Every network flow out of a workspace, explained end to end:

```
reasoning ("I'll check connectivity first…")
  → tool call  Bash `ping -c1 1.1.1.1`          (the AI proxy saw it in the model's response)
  → processes  claude (412) → bash (980) → ping (981)   (the kernel sentry)
  → flow       ICMP echo → 1.1.1.1              (the kernel sentry)
  → decision   passed (ICMP isn't filtered)     (the host switch / firewall / L7 policy)
```

Three parts, one contract (this file):

| Part | Who | What |
|---|---|---|
| Guest kernel sentry | @linux-dev | `exec` gains argv + start time; new `net_flow` events with the process chain, including ICMP |
| Host | Bromure AC (openshell branch) | tool-call ids + reasoning from the AI proxy, a per-VM process table, the join, the `net.flow` event, local Security Timeline rows |
| Cloud | @infra (bromure-infra) | ingest, retention, and the viewer |

## 1. Guest → host (sentry vsock 5841, existing framing)

### `exec` (existing kind, enriched)
Still counted-only on the host's Security Timeline; the host keeps it in memory to build the
process tree. Added fields:

- `argv`: the command line, NUL-separated args joined with single spaces, at most 1024 bytes
  (`argv_truncated: true` when cut). Read in the exec hook from the new mm's arg area.
- `start_ns`: the task's start time (`start_boottime`, ns). `(pid, start_ns)` is a process's
  identity: pids are reused, start times aren't.
- `ppid`, `pid`, `comm`, `path` (exe), `uid`, `sandboxed`: as today.

### `net_flow` (new kind)
One event when a socket first talks to a destination, never per packet:

- **When:** TCP once the source port is chosen (`tcp_connect`, a real SYN); UDP **only** on a
  send that has a destination (`udp_sendmsg`/`udpv6_sendmsg`). Never on a datagram `connect()`:
  that sends nothing (iputils' source-address probe to :1025, `getaddrinfo` route lookups), so
  `ip4/ip6_datagram_connect` must not be probed (removed in guest round 27). ICMP through ping sockets (`ping_v4/v6_sendmsg`) and raw
  sockets (`raw_sendmsg`/`rawv6_sendmsg`).
- **ICMP on the Bromure image (measured):** `ping_group_range` was empty, so `ping` used a raw
  socket via its `cap_net_raw` file capability, which strict mode strips (no `ping` at all in a
  strict sandbox). Decided: the guest sets `net.ipv4.ping_group_range` to the **workload's** gid (`plan.gid`:
  the workspace user, or the `run_as_user` account, with a warning that the owner's shell then
  loses ping) at boot (runtime only), so a sandboxed `ping` uses a ping socket (ICMP echo only, no
  capability) and is seen by `ping_v4_sendmsg`. `ping` also calls `connect()`, so the old
  `connect` probe did see it, without the chain. Dedup per (pid, proto, dst, dport) within 10 s
  (`flow_dedup_ms`); "per socket for its life" is only approximated by that window (per-socket
  state would need `sk_user_data`, which the protocol owns), which changes nothing for TCP.
- **Fields:** `proto` (`tcp` | `udp` | `icmp` | `icmpv6` | `raw`), `ip_proto` (number),
  `family`, `dst`, `dport` (0 for ICMP), `sport` (local port; for ping sockets the ICMP echo
  identifier), `icmp_type` when cheap (8 = echo), `pid`, `start_ns`, `comm`, `path` (exe),
  `uid`, `sandboxed`.
- **`chain`:** the ancestors, nearest first, up to 8: `[{pid, start_ns, comm}]`. The host
  normally rebuilds the tree from `exec`; the chain covers processes that started before the
  sentry loaded, and pid reuse.
- **Cost:** measured like `security_file_open` (ns per connect/send on a busy workload).
- Rate-limited and folded like `sandbox_denied` (a `count` on folded repeats).

The existing `connect` kind can stay for the attestor cross-check, or be retired in favour of
`net_flow`; the host accepts both.

## 2. Host-side join (AgentCoding)

1. **Tool calls.** The AI proxy already parses each response (`LLMEventExtractor`). It now keeps
   every tool call with its provider id (`tool_use_id`, or OpenAI's `call_id`), tool, input
   (the command for shell tools), and the reasoning just before it in the same assistant turn
   (thinking + text, at most 2000 chars). Pending calls are kept 10 minutes. `tool.use`,
   `command.run`, `file.*` gain `tool_use_id`.
2. **Process table** per VM from `exec`/`net_flow`: `(pid, start_ns) → {ppid, comm, exe, argv}`.
3. **Shell ↔ tool call.** A shell exec'd under the agent process whose argv contains the tool
   call's command (after undoing the agent's quoting: Claude Code runs
   `bash -c '… eval '"'"'<cmd>'"'"' …'`) within 30 s after the response. `confidence`:
   `exact` (normalized command found in argv), `fuzzy` (first word + timing + agent
   ancestry), `none`.
4. **Flow ↔ decision.** Match the switch's egress decision on (proto, dst, dport, and sport when
   present) within 5 s; the L7 (MITM) decision for the same 5-tuple when it was inspected.
   ICMP isn't filtered: `decision: "unfiltered"`.

### Through the guest's proxy bridge
Ordinary (non-OpenShell) workspaces set `HTTPS_PROXY=http://127.0.0.1:65534`: curl, npm, pip
and git-over-https connect to agentd's bridge on loopback, which relays the bytes to the host
MITM over vsock 8443. Measured on a fresh VM: `curl https://1.1.1.1/` produced no flow at all.
So:
- the sentry reports loopback flows whose dport is the proxy port (module parameter
  `flow_local_ports`; other loopback stays counted only);
- the bridge opens each vsock stream with `BROMURE-CLIENT 1 sport=<client port> peer=<ip>\n`;
- the host MITM strips that line (`HTTPMitmConnection.stripClientPreamble`) and records
  `sport → CONNECT target` (`NetworkLineage.noteProxied`); a loopback flow with that sport is
  reported as the real destination with `via_proxy: true`, and the proxy's decision (L7,
  keyed by hostname; no refusal logged = allowed).

## 3. Host → cloud (`/v1/installs/:id/ac-events`, existing batches)

### `net.flow` (new)
One per distinct flow, folded per (leaf exe, proto, dst, dport) per 60 s with `count` (a folded
upload carries `repeat: true`). Every uploaded event has its own `flow_id` (the viewer's row
key). `processes` holds the 8 processes nearest the flow, root → leaf, each with an optional
`start_ns`. `decision: "unknown"` = TCP/UDP the host logged no decision for (its per-destination
report is rate-limited); `"unfiltered"` = protocols the switch doesn't filter (ICMP, raw).

```json
{
  "flow_id": "uuid",
  "proto": "icmp", "dst": "1.1.1.1", "dport": 0, "sport": 4321,
  "host": "one.one.one.one",            // DNS-snooped name, when known
  "decision": "allow" | "deny" | "audit" | "unfiltered",
  "layer": "l4" | "l7" | "identity",     // who decided
  "reason": "…",                          // when denied / audited
  "count": 1,
  "processes": [                          // root → leaf, from the agent down
    {"pid": 412, "comm": "claude", "exe": "/usr/bin/node", "argv": "claude"},
    {"pid": 980, "comm": "bash", "exe": "/usr/bin/bash", "argv": "bash -c …"},
    {"pid": 981, "comm": "ping", "exe": "/usr/bin/ping", "argv": "ping -c1 1.1.1.1"}
  ],
  "agent": {"tool": "Bash", "tool_use_id": "toolu_…", "confidence": "exact"}
}
```

### `agent.reasoning` (new, opt-in)
`{tool_use_id, tool, text, truncated}`: the reasoning behind one tool call, at most once per
`tool_use_id`; `tool_use_id` ≤128 chars everywhere. The org flag arrives as top-level
`capture_agent_reasoning` (bool) in `GET /v1/installs/:id/openshell-policy`, next to
`min_kernel_sentry`; absent ⇒ false. Uploaded **only**
when the organization turns on `capture_agent_reasoning` (managed policy, default off), never
for private profiles. `LLMEventExtractor`'s posture so far was "what the AI did, never what it
said"; this is the one deliberate exception, and it is the org's call. Locally (the user's own
Security Timeline) it is always shown.

### Viewer (bromure-infra)
Per session, the network streams: one row per `net.flow`, expandable to the full lineage
(reasoning → tool call → processes → flow → decision), filterable by decision, destination,
process and tool; denied and unfiltered flows first; a graph view of the process tree with
flows as leaves. Joins: `net.flow.agent.tool_use_id` ↔ `command.run`/`tool.use`/`agent.reasoning`
`tool_use_id`, same session.

## 4. Volume and privacy
- `exec` never leaves the host. `net.flow` is folded (60 s) and bounded per batch by the
  uploader (500 events, 1 MiB).
- argv is capped (1024 bytes guest, 256 bytes per process in `net.flow`); the MITM's
  credential redaction applies to argv before upload (tokens on command lines).
- Private profiles upload nothing (existing emitter gate).
