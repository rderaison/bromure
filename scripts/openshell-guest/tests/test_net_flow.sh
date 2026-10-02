#!/usr/bin/env bash
# Network lineage: drive real tools and assert the sentry reports each flow with
# the process chain that caused it.
#
# THIS IS THE SCRIPT FOR A FRESH VM. It loads the testable sentry build, so it
# cannot run anywhere kernel lockdown has been raised -- lockdown is one-way for
# the life of the boot and `integrity` refuses unsigned modules. It skips loudly
# and exits 77 in that case rather than reporting a pass it did not earn.
#
# What it drives, and the probe each one is there to prove:
#
#   ping -c1                  ICMP via a ping socket      ping_v4_sendmsg
#   a ping socket bound to a   ICMP with a KNOWN echo id, so `sport` is
#     chosen port              asserted exactly rather than "non-zero"
#   a raw-socket echo request  RAW                        raw_sendmsg
#   curl, and a bare connect   TCP                        tcp_connect
#   an unconnected UDP send    UDP                        udp_sendmsg
#   a connected UDP send       UDP                        ip4_datagram_connect
#   dig @1.1.1.1, nc -u        when installed (neither is on the base image)
#   the same over IPv6         when the VM has a v6 route
#
# and, for every one of them, that `chain` names the shell that spawned it.
#
# It also asserts what must NOT happen: no event per packet, loopback flows
# counted rather than emitted, and a ping socket reporting its send rather than
# its connect (the connect has no echo identifier yet).
#
# Finally it measures the cost the contract asks for -- ns per connect and per
# send with the module loaded against the same loop with it unloaded.
#
# Run: tests/test_net_flow.sh
#   PORT=5841  SECONDS_TO_WATCH=40  DEST=1.1.1.1  DEST6=2606:4700:4700::1111
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
SENTRY="$ROOT/sentry"
PORT=${PORT:-5841}
SECONDS_TO_WATCH=${SECONDS_TO_WATCH:-40}
DEST=${DEST:-1.1.1.1}
DEST6=${DEST6:-2606:4700:4700::1111}
PING_RANGE=/proc/sys/net/ipv4/ping_group_range
# A port of our own, NOT the real proxy port: on a fresh VM agentd is live and
# bound to 0.0.0.0:<proxy_port>, so driving curl at the real one would reach the
# real bridge and the real host MITM. This suite stays self-contained.
PROXY_TEST_PORT=${PROXY_TEST_PORT:-65533}
# The real one too, when the meta share says, so a plain `curl` that the
# workspace's own HTTPS_PROXY redirects is reported rather than suppressed.
REAL_PROXY_PORT=$(cat /mnt/bromure-meta/proxy_port 2>/dev/null | tr -dc '0-9')
REAL_PROXY_PORT=${REAL_PROXY_PORT:-65534}

FRAMES=$(mktemp /tmp/netflow-frames-XXXXXX.json)
SINK_LOG=$(mktemp /tmp/netflow-sink-XXXXXX.log)
PIDS=$(mktemp -d /tmp/netflow-pids-XXXXXX)
chmod 755 "$PIDS"
fails=0
skips=0

say()  { printf '\n=== %s ===\n' "$1"; }
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }
skip() { printf '  SKIP %s\n' "$1"; skips=$((skips + 1)); }

PING_SAVED=""
cleanup() {
    sudo rmmod bromure_sentry 2>/dev/null
    [ -n "$PING_SAVED" ] && \
        sudo sh -c "printf '%s' '$PING_SAVED' > $PING_RANGE" 2>/dev/null
    rm -rf "$FRAMES" "$SINK_LOG" "$PIDS"
}
trap cleanup EXIT

# ---------------------------------------------------------------- preflight --
say "preflight"
LOCKDOWN_NOW=$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/kernel/security/lockdown 2>/dev/null)
if [ -n "$LOCKDOWN_NOW" ] && [ "$LOCKDOWN_NOW" != "none" ]; then
    printf '\n  SKIPPED: this VM is at lockdown=%s, which refuses unsigned\n' "$LOCKDOWN_NOW"
    printf '           modules. Lockdown is one-way until reboot, so this\n'
    printf '           suite cannot load its build here. Run it on a fresh VM.\n'
    printf '\n  THE NETWORK LINEAGE SUITE DID NOT RUN.\n\n'
    exit 77
fi
ok "lockdown=none, the build can be loaded"

# `ping` tries socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP) FIRST and only falls
# back to SOCK_RAW on EACCES. Ubuntu ships `ping_group_range = 1 0` -- an empty
# range -- so the fallback is what normally happens, and inside the sandbox the
# fallback cannot work at all, because no_new_privs means the cap_net_raw on
# /usr/bin/ping is not honoured. `bromure-sandboxd` sets this at boot for the
# workload's gid; this suite sets it for whoever is running it, and puts the old
# value back on the way out.
PING_SAVED=$(cat "$PING_RANGE")
MY_GID=$(id -g)
sudo sh -c "echo '$MY_GID $MY_GID' > $PING_RANGE"
ok "ping_group_range = $(tr '\t' ' ' < $PING_RANGE) (was $(printf '%s' "$PING_SAVED" | tr '\t' ' '))"

say "build (testable)"
make -C "$SENTRY" clean > /dev/null 2>&1
make -C "$SENTRY" EXTRA_CFLAGS=-DBROMURE_SENTRY_TESTABLE > /tmp/netflow-build.log 2>&1 \
    || { bad "build (see /tmp/netflow-build.log)"; exit 1; }
if grep -q "frame size" /tmp/netflow-build.log; then
    # The event is 1792 bytes; staging one on the stack in a probe handler put
    # 1808-byte frames inside udp_sendmsg and the LSM hooks. The handlers use a
    # per-CPU buffer now, and this is here so that cannot come back unnoticed.
    bad "the build warns about stack frame size: $(grep -c 'frame size' /tmp/netflow-build.log) function(s)"
else
    ok "built with no stack-frame warnings"
fi

say "load"
sudo modprobe vsock_loopback 2>/dev/null
sudo rmmod bromure_sentry 2>/dev/null
python3 "$HERE/vsock_sink.py" --port "$PORT" --seconds "$SECONDS_TO_WATCH" \
    --json-out "$FRAMES" > "$SINK_LOG" 2>&1 &
SINK=$!
sleep 1
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)
sudo insmod "$SENTRY/bromure_sentry.ko" cid=1 port="$PORT" boot_id="$BOOT_ID" \
    flow_local_ports="$PROXY_TEST_PORT,$REAL_PROXY_PORT" \
    || { bad "insmod"; exit 1; }
ok "loaded (cid=1 port=$PORT flow_local_ports=$PROXY_TEST_PORT,$REAL_PROXY_PORT)"
echo 1 | sudo tee /sys/module/bromure_sentry/parameters/phase > /dev/null
ok "phase=session"

# The proxy exemption must not be rewritable by the thing being watched. It is
# the one flow parameter whose value can make the sentry report LESS: dropping
# the proxy port out of it would suppress every HTTP request the agent makes as
# ordinary loopback plumbing. Root still has that power in the non-strict mode,
# so the file is 0444 and the kernel refuses the write.
PARAM=/sys/module/bromure_sentry/parameters/flow_local_ports
BEFORE=$(sudo cat "$PARAM" 2>/dev/null)
if echo 1 | sudo tee "$PARAM" > /dev/null 2>&1; then
    bad "root rewrote flow_local_ports (now '$(sudo cat "$PARAM")'): that is a one-line way for an agent to hide its own proxied egress"
else
    ok "flow_local_ports is not writable after load, even for root"
fi
check_after=$(sudo cat "$PARAM" 2>/dev/null)
if [ "$check_after" = "$BEFORE" ]; then
    ok "and it still reads '$BEFORE' after the refused write"
else
    bad "flow_local_ports changed from '$BEFORE' to '$check_after'"
fi

# ------------------------------------------------------------------- drivers --
# Each driver runs under its own `bash -c`, which records its own pid, so that
# "the chain names the shell that spawned it" can be asserted against a pid this
# script knows.
#
# THE TRAILING `:` IS LOAD-BEARING. `bash -c 'a; cmd'` execs `cmd` in place when
# `cmd` is the last simple command -- measured: the wrapper's `$$` and the
# command's pid come back identical. That would make `wpid` the command's OWN pid
# instead of its parent's, and every chain assertion below would fail for a
# reason that has nothing to do with the module. With a no-op after it bash
# forks, and the wrapper survives as the real parent.
#
# (Checking this with a PIPELINE as the last command hides it, because a pipeline
# forks anyway. The shape has to be the one the script actually uses.)
drive() {
    local label="$1"; shift
    bash -c "echo \$\$ > '$PIDS/$label'; $*; :" > /dev/null 2>&1
    return 0
}
wpid() { cat "$PIDS/$1" 2>/dev/null || echo 0; }

say "drive the flows"

drive ping "ping -c1 -W2 $DEST"
ok "ping -c1 $DEST (wrapper pid $(wpid ping))"

# A ping socket bound to a port we choose, so the echo identifier is KNOWN and
# `sport` can be asserted exactly. "non-zero" would pass even if the field were
# wired to the wrong number.
drive pingid "python3 -c \"
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_ICMP)
s.bind(('', 4242))
s.sendto(b'\\x08\\x00\\xf7\\xfe\\x10\\x92\\x00\\x01bromure', ('$DEST', 0))
\""
ok "a ping socket bound to port 4242 (wrapper pid $(wpid pingid))"

drive rawping "sudo python3 -c \"
import array, socket, struct
def ck(d):
    if len(d) % 2: d += b'\\x00'
    c = sum(array.array('H', d)); c = (c >> 16) + (c & 0xffff)
    return (~c) & 0xffff
body = struct.pack('!BBHHH', 8, 0, 0, 0x4243, 1) + b'bromure'
pkt = struct.pack('!BBHHH', 8, 0, ck(body), 0x4243, 1) + b'bromure'
s = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP)
s.sendto(pkt, ('$DEST', 0))
\""
ok "a raw-socket echo request (wrapper pid $(wpid rawping))"

# A bare TCP connect as well as curl: the TCP assertion must not depend on a
# tool being installed, and `dig` and `nc` are NOT on the base image -- measured.
drive tcp "python3 -c \"
import socket
s = socket.socket(); s.settimeout(3)
try: s.connect(('$DEST', 443))
except OSError: pass
\""
ok "a TCP connect to $DEST:443 (wrapper pid $(wpid tcp))"

if command -v curl > /dev/null 2>&1; then
    # `--noproxy '*'` is load-bearing. The first version of this just ran
    # `curl https://$DEST/` and found no flow on a real VM -- because agentd
    # sets HTTPS_PROXY=http://127.0.0.1:<proxy_port> in every non-OpenShell
    # workspace, so curl never connected to $DEST at all. It went to loopback,
    # which was suppressed as plumbing. Bypassing the proxy is what makes this
    # a test of a direct TCP flow.
    drive curl "curl -s -m5 --noproxy '*' -o /dev/null https://$DEST/"
    ok "curl direct to $DEST, proxy bypassed (wrapper pid $(wpid curl))"
    # And the proxied case, which is what nearly every real client does:
    # the flow goes to LOOPBACK and must be reported anyway, because its
    # `sport` is how the host joins it to the CONNECT target the MITM saw.
    drive curlproxy \
        "curl -s -m3 --proxy http://127.0.0.1:$PROXY_TEST_PORT -o /dev/null https://$DEST/"
    ok "curl through a proxy on 127.0.0.1:$PROXY_TEST_PORT (wrapper pid $(wpid curlproxy))"
else
    skip "curl is not installed"
fi

drive udp "python3 -c \"
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.sendto(b'bromure', ('$DEST', 53))
\""
ok "an unconnected UDP send to $DEST:53 (wrapper pid $(wpid udp))"

drive udpc "python3 -c \"
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.connect(('$DEST', 5353)); s.send(b'bromure')
\""
ok "a connected UDP send to $DEST:5353 (wrapper pid $(wpid udpc))"

# Connect and NEVER send. A datagram connect is not a packet -- it only records
# where the socket would send -- so this must produce no flow at all. It is what
# iputils does to pick a source address, and probing the connect put
# "bash -> ping -> UDP 1.1.1.1:1025" on the timeline for traffic that never
# existed.
drive udpnosend "python3 -c \"
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.connect(('$DEST', 7777))
s.close()
\""
ok "a UDP socket connected to $DEST:7777 that never sends (wrapper pid $(wpid udpnosend))"

# A send with NOWHERE to send it. `udp_sendmsg` runs before the syscall fails
# with EDESTADDRREQ -- measured -- so without a guard this emits a flow to
# 0.0.0.0 for a packet that never left.
drive nodest "python3 -c \"
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try: s.send(b'bromure')
except OSError: pass
\""
ok "a send on an unconnected UDP socket, which cannot go anywhere (wrapper pid $(wpid nodest))"

for tool in dig nc; do
    if command -v "$tool" > /dev/null 2>&1; then
        case "$tool" in
          dig) drive dig "dig +time=3 +tries=1 @$DEST example.com" ;;
          nc)  drive nc  "echo hi | timeout 2 nc -u -w1 $DEST 53" ;;
        esac
        ok "$tool (wrapper pid $(wpid $tool))"
    else
        skip "$tool is not installed on this image"
    fi
done

HAVE_V6=0
if ip -6 route get "$DEST6" > /dev/null 2>&1; then
    HAVE_V6=1
    drive tcp6 "python3 -c \"
import socket
s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM); s.settimeout(3)
try: s.connect(('$DEST6', 443))
except OSError: pass
\""
    drive ping6 "ping -6 -c1 -W2 $DEST6"
    ok "IPv6: a TCP connect and a ping to $DEST6"
else
    skip "this VM has no IPv6 route to $DEST6; the v6 probes are not exercised"
fi

# Loopback must be counted, not emitted: measured, 93 of 97 flow probe hits on
# an otherwise quiet VM were datagram connects to the systemd-resolved stub.
drive local "python3 -c \"
import socket
for _ in range(20):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.sendto(b'x', ('127.0.0.1', 9)); s.close()
\""
ok "20 loopback sends, which must not become 20 events"

# One event per flow, never one per packet.
drive burst "ping -c5 -i0.2 -W2 $DEST"
ok "ping -c5 (five packets, one flow)"

# THREE DESTINATIONS FROM ONE PROCESS. The regression test for the bug this
# suite found on its first real run: the dedup key did not contain the
# destination, so every flow a process made in the window folded into its first
# one -- a `ping -c1` arrived as a single UDP event with `count: 2`, the ICMP
# send absorbed into iputils' source-address probe. One process, three distinct
# destinations, three events.
# ONE process, TWO protocols, THREE destinations -- the properties the dedup
# key has to keep apart, driven directly rather than as a side effect of how
# `ping` happens to behave this round.
drive multiproto "python3 -c \"
import socket
s = socket.socket(); s.settimeout(2)
try: s.connect(('$DEST', 443))
except OSError: pass
s.close()
u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
u.sendto(b'bromure', ('$DEST', 5401))
u.sendto(b'bromure', ('1.0.0.1', 5402))
u.close()
\""
ok "one process, tcp + udp, three destinations (wrapper pid $(wpid multiproto))"

drive manydst "python3 -c \"
import socket
for host, port in (('$DEST', 443), ('$DEST', 8080), ('1.0.0.1', 443)):
    s = socket.socket(); s.settimeout(2)
    try: s.connect((host, port))
    except OSError: pass
    s.close()
\""
ok "one process, three destinations (wrapper pid $(wpid manydst))"

# argv, including the truncation flag.
drive argvshort "/bin/echo bromure-argv-marker alpha beta gamma"
LONG=$(python3 -c "print(' '.join('x%d' % i for i in range(400)))")
drive argvlong "/bin/echo bromure-argv-long $LONG"
# An EMPTY argument is an ordinary thing to exec, and the reader used to stop at
# the first one and call the result truncated -- so `cmd '' x` was reported as
# `cmd`. Driven here because nothing else in the suite passes one.
drive argvempty "/bin/echo bromure-argv-empty '' tail-survived"
ok "exec with a short argv, one over 1024 bytes, and one with an empty argument"

# A nested shell, so the chain has real depth and its order can be checked.
drive nested "bash -c 'echo \$\$ > $PIDS/nested_inner; python3 -c \"
import socket
s = socket.socket(); s.settimeout(3)
try: s.connect((\\\"$DEST\\\", 8443))
except OSError: pass
\"; :'"
ok "a nested shell -> python -> connect (outer $(wpid nested), inner $(wpid nested_inner))"

say "wait for the capture to close"
wait "$SINK" 2>/dev/null
ok "sink finished ($(wc -c < "$FRAMES") bytes of frames)"

# ----------------------------------------------------------------- assertions --
say "assertions"
if [ ! -s "$FRAMES" ]; then
    bad "no frames were captured at all"
else
    PIDS="$PIDS" HAVE_V6="$HAVE_V6" DEST="$DEST" DEST6="$DEST6" \
        PROXY_TEST_PORT="$PROXY_TEST_PORT" REAL_PROXY_PORT="$REAL_PROXY_PORT" \
        python3 - "$FRAMES" <<'PY'
import json, os, sys

frames = json.load(open(sys.argv[1]))
events = [f for f in frames if f.get("type") == "event"]
beats = [f for f in frames if f.get("type") == "heartbeat"]
flows = [e for e in events if e.get("kind") == "net_flow"]
execs = [e for e in events if e.get("kind") == "exec"]
PIDS = os.environ["PIDS"]
DEST, DEST6 = os.environ["DEST"], os.environ["DEST6"]
HAVE_V6 = os.environ["HAVE_V6"] == "1"
fails = []

def wpid(label):
    try:
        return int(open(os.path.join(PIDS, label)).read().strip())
    except (OSError, ValueError):
        return 0

def ok(msg):   print("  ok   %s" % msg)
def bad(msg):  print("  FAIL %s" % msg); fails.append(msg)

def pick(**match):
    out = []
    for e in flows:
        if all(e.get(k) == v for k, v in match.items()):
            out.append(e)
    return out

def chain_pids(e):
    return [a["pid"] for a in (e.get("chain") or [])]

def expect(label, what, **match):
    """One flow matching `match`, whose chain names the shell that spawned it."""
    found = pick(**match)
    if not found:
        bad("%s: no net_flow matching %s" % (label, match))
        print("       flows seen: %s" % json.dumps(
            [{k: e.get(k) for k in ("comm", "proto", "dst", "dport", "sport")}
             for e in flows], sort_keys=True)[:900])
        return None
    e = found[0]
    ok("%s: %s" % (label, what))
    shell = wpid(label)
    if shell and shell in chain_pids(e):
        ok("%s: the chain names the shell that spawned it (pid %d, %s)"
           % (label, shell, (e["chain"][0] or {}).get("comm")))
    elif shell:
        bad("%s: chain %s does not contain the spawning shell %d"
            % (label, chain_pids(e), shell))
    return e

print("  --- what arrived -------------------------------------------------")
kinds = {}
for e in events:
    kinds[e["kind"]] = kinds.get(e["kind"], 0) + 1
ok("event kinds: %s" % json.dumps(kinds, sort_keys=True))
ok("net_flow events: %d" % len(flows))

# A connect() must now produce ONE kind, not two. The old `connect` event
# duplicated every TCP connection with less information -- no protocol, no
# source port, no start time, no chain -- and had no dedup at all, so it was the
# noisiest kind in the module. Retired once the host confirmed nothing read it;
# the ABI number stays reserved so it can never mean something else.
stale = [e for e in events if e.get("kind") == "connect"]
if stale:
    bad("%d `connect` event(s) were emitted; the kind is retired and "
        "`net_flow` supersedes it" % len(stale))
else:
    ok("a connect() produces only net_flow -- the `connect` kind is gone")
# And the probe itself is not registered, so this is not merely "none happened".
hello = next((f for f in frames if f.get("type") == "hello"), {})
probes = " ".join(hello.get("probes") or []) if isinstance(hello.get("probes"), list) \
    else str(hello.get("probes", ""))
if "security_socket_connect" in probes:
    bad("security_socket_connect is still registered as a probe")
elif probes:
    ok("and security_socket_connect is not among the registered probes")

print("  --- every flow carries the contract's fields ---------------------")
# Every field the contract's §1 field list names. `path` was missing from this
# tuple, which is how `net_flow` shipped emitting `"path": ""` for a round: the
# key was present in the JSON, so a mere key-presence check passed, and nothing
# asserted it had a value.
REQUIRED = ("proto", "ip_proto", "family", "dst", "dport", "sport",
            "pid", "start_ns", "comm", "path", "uid", "sandboxed", "count")
missing = {}
for e in flows:
    for key in REQUIRED:
        if key not in e:
            missing.setdefault(key, 0)
            missing[key] += 1
if missing:
    bad("fields absent from some flows: %s" % missing)
else:
    ok("all of %s on every flow" % ", ".join(REQUIRED))
if flows and all(e.get("chain") for e in flows):
    ok("every flow carries a chain")
elif flows:
    bad("%d flow(s) carry no chain" % sum(1 for e in flows if not e.get("chain")))

# And `path` has to hold the exe, not merely exist. The host needs it for a
# process that started before the sentry loaded: there is no `exec` event to
# look the binary up from, which is the same gap `chain` exists to cover.
blank = [e for e in flows if not e.get("path")]
if flows and not blank:
    ok("every flow names its exe, e.g. %r" % flows[0]["path"])
elif flows:
    bad("%d of %d flow(s) have an empty path; a flow from a process that "
        "started before the sentry loaded has no exec event to resolve the "
        "binary from" % (len(blank), len(flows)))
absolute = [e for e in flows if e.get("path") and not e["path"].startswith("/")]
if absolute:
    bad("flow path(s) are not absolute: %s" % [e["path"] for e in absolute][:3])
elif flows:
    ok("and the path is absolute, as file_path renders it")
# The exe and the comm should agree for the simple cases driven here.
mismatch = [e for e in flows
            if e.get("comm") and e.get("path")
            and not e["path"].endswith("/" + e["comm"])
            and e["comm"] not in ("python3",)]
if mismatch:
    print("  note %d flow(s) whose exe basename differs from comm, which is "
          "normal for interpreters and renames: %s"
          % (len(mismatch), [(e.get("comm"), e.get("path")) for e in mismatch][:3]))
else:
    ok("the exe basename matches comm for the drivers that have one")

print("  --- ICMP ---------------------------------------------------------")
e = expect("ping", "ICMP via a ping socket", kind="net_flow", comm="ping",
           proto="icmp", dst=DEST)
if e:
    if e.get("dport") == 0:
        ok("ping: dport is 0, as the contract says for ICMP")
    else:
        bad("ping: dport is %r, expected 0 for ICMP" % e.get("dport"))
    if e.get("ip_proto") == 1:
        ok("ping: ip_proto 1")
    else:
        bad("ping: ip_proto is %r, expected 1" % e.get("ip_proto"))
    if e.get("icmp_type") == 8:
        ok("ping: icmp_type 8 (echo request), read from the message")
    elif "icmp_type" in e:
        bad("ping: icmp_type is %r, expected 8 for an echo request"
            % e.get("icmp_type"))
    else:
        bad("ping: no icmp_type at all; the contract asks for it when cheap, "
            "and one guarded byte through copy_from_user_nofault is cheap")
    if e.get("sport"):
        ok("ping: sport %d (the echo identifier)" % e["sport"])
    else:
        bad("ping: sport is %r -- the echo identifier is the one number that "
            "lets the host match a reply to a request" % e.get("sport"))

e = expect("pingid", "a ping socket with a known echo id", kind="net_flow",
           proto="icmp", sport=4242)
if e:
    ok("pingid: sport is exactly the port we bound (4242), so the field is "
       "wired to the identifier and not to something that merely looks set")

print("  --- ping's OWN udp socket, which is not a mislabelled ping socket -")
# The first version of this check asserted that NO flow from `ping` is udp, and
# it was wrong: iputils probes its source address by connecting a real
# SOCK_DGRAM/IPPROTO_UDP socket to dst:1025 before it pings. That flow is
# genuinely udp and genuinely worth reporting.
#
# What a MISLABELLED ping socket would look like is udp with `dport: 0`, because
# a ping socket has no destination port -- `ip4_datagram_connect` is udp_prot's
# connect AND ping_prot's, so a static per-probe label put exactly that on the
# wire. So the assertion is on that shape, not on "udp from ping".
# iputils connects a UDP socket to dst:1025 purely to ask the routing table
# which source address it would use, and never sends a byte. That connect must
# NOT be a row: it appeared live as "bash -> ping -> UDP 1.1.1.1:1025", a flow
# for a packet that never existed. UDP is reported on its first SEND now.
probe = [e for e in flows if e.get("comm") == "ping" and e.get("proto") == "udp"
         and e.get("dport") == 1025]
if probe:
    bad("iputils' source-address probe produced %d net_flow(s) to port 1025: a "
        "datagram connect is not a packet and must not be reported"
        % len(probe))
else:
    ok("ping's source-address probe (connect to :1025, never sends) produces "
       "no flow")
mislabelled = [e for e in flows if e.get("comm") == "ping"
               and e.get("proto") == "udp" and e.get("dport") == 0]
if mislabelled:
    bad("%d ping flow(s) are udp with dport 0 -- that is a ping socket wearing "
        "the probe's label instead of the socket's" % len(mislabelled))
else:
    ok("no ping socket was reported as udp with dport 0")

print("  --- the dedup key distinguishes destinations ----------------------")
# The bug this suite caught on its first real run: the dedup key carried no
# destination, so every flow a process made in the window folded into its first.
#
# This used `ping`, which then made both a udp source probe and an icmp send
# from one pid. A later round removed the datagram-connect probes on purpose --
# a connect is not a packet -- so ping now emits ONLY icmp and the old
# assertion was asserting the behaviour that had been deliberately removed. It
# took a run on a VM that can load the module to notice, because this suite
# cannot run where it was written.
#
# So the property is driven directly instead: one process, two protocols.
multi = wpid("multiproto")
if multi:
    mine = [e for e in flows if multi in chain_pids(e)]
    protos = sorted(set(e.get("proto") for e in mine))
    dests = sorted(set((e.get("proto"), e.get("dst"), e.get("dport")) for e in mine))
    if len(protos) >= 2:
        ok("one process's %s flows are reported separately, not folded into one"
           % protos)
    else:
        bad("one process did tcp AND udp but only %s was reported: the dedup "
            "key is dropping the protocol" % protos)
    if len(dests) >= 3:
        ok("and its three destinations are three events: %s" % dests)
    else:
        bad("three destinations collapsed to %d: %s" % (len(dests), dests))
else:
    bad("the multi-protocol driver recorded no pid")

# And `ping` emitting ONLY icmp is now the EXPECTED outcome, not a failure:
# its source-address probe connects a udp socket and never sends, and a connect
# is not a flow.
for p in sorted(set(e.get("pid") for e in flows if e.get("comm") == "ping")):
    protos = sorted(set(e.get("proto") for e in flows if e.get("pid") == p))
    if protos == ["icmp"]:
        ok("ping pid %d reported only ['icmp'], as it should: its udp source "
           "probe never sends" % p)
    else:
        bad("ping pid %d reported %s; only icmp should survive now that a "
            "datagram connect is not probed" % (p, protos))
many = wpid("manydst")
dsts = sorted(set((e.get("dst"), e.get("dport")) for e in flows
                  if many and many in chain_pids(e)))
if len(dsts) >= 3:
    ok("one process's three destinations are three events: %s" % dsts)
elif dsts:
    bad("one process's three destinations collapsed to %d event(s): %s -- the "
        "dedup key is dropping the destination" % (len(dsts), dsts))
else:
    bad("the three-destination driver produced no flow at all")

print("  --- RAW ----------------------------------------------------------")
e = expect("rawping", "a raw socket is its own protocol, not icmp",
           kind="net_flow", proto="raw", dst=DEST)
if e and e.get("ip_proto") == 1:
    ok("rawping: ip_proto 1 with proto=raw -- SOCK_RAW is a different "
       "capability from a ping socket and is bucketed separately")
if e is not None:
    # Deliberately absent for raw. With IP_HDRINCL the first byte is the IP
    # header's version/IHL (0x45), which would be reported as icmp_type 69.
    # A field that is honestly absent beats one that is confidently wrong.
    if "icmp_type" not in e:
        ok("rawping: no icmp_type, because a raw socket's first byte depends "
           "on IP_HDRINCL and is not the type")
    else:
        bad("rawping: icmp_type %r was reported for a RAW socket, where byte 0 "
            "may be the IP header" % e.get("icmp_type"))

print("  --- TCP ----------------------------------------------------------")
e = expect("tcp", "TCP on connect", kind="net_flow", proto="tcp", dst=DEST,
           dport=443)
if e:
    if e.get("sport"):
        ok("tcp: sport %d -- chosen by the time tcp_connect runs, which is why "
           "that is the probe point" % e["sport"])
    else:
        bad("tcp: sport is %r; tcp_connect should run after the source port is "
            "chosen" % e.get("sport"))
if wpid("curl"):
    expect("curl", "a real client over TCP, straight out", kind="net_flow",
           comm="curl", proto="tcp", dst=DEST, dport=443)

print("  --- a proxied client: loopback, and reported anyway ---------------")
# Everything the agent actually runs -- curl, npm, pip, git-over-https -- is
# pointed at 127.0.0.1:<proxy_port> by agentd. A blanket loopback filter
# suppressed every one of them, which is the opposite of the mistake the filter
# exists to prevent. `flow_local_ports` exempts the proxy port.
if wpid("curlproxy"):
    e = expect("curlproxy", "a flow to the proxy on loopback is reported",
               kind="net_flow", comm="curl", proto="tcp",
               dst="127.0.0.1", dport=int(os.environ["PROXY_TEST_PORT"]))
    if e:
        if e.get("sport"):
            ok("curlproxy: sport %d -- this is the number the host joins to "
               "the CONNECT target the MITM saw on that connection" % e["sport"])
        else:
            bad("curlproxy: sport is %r, so there is nothing to join on"
                % e.get("sport"))
    # And the exemption must be narrow: other loopback ports stay suppressed.
    other = [f for f in flows if str(f.get("dst", "")).startswith("127.")
             and f.get("dport") not in (int(os.environ["PROXY_TEST_PORT"]),
                                        int(os.environ["REAL_PROXY_PORT"]))]
    if other:
        bad("%d loopback flow(s) to non-proxy ports were reported: %s -- the "
            "exemption is supposed to be one port, not loopback in general"
            % (len(other), [(f.get("dst"), f.get("dport")) for f in other]))
    else:
        ok("loopback to every other port is still suppressed, so the exemption "
           "did not reopen the flood")

print("  --- UDP ----------------------------------------------------------")
expect("udp", "an unconnected send names its destination per message",
       kind="net_flow", proto="udp", dst=DEST, dport=53)
expect("udpc", "a connected datagram socket reports on its first SEND",
       kind="net_flow", proto="udp", dst=DEST, dport=5353)
nowhere = [e for e in flows if e.get("dst") in ("0.0.0.0", "::", "")]
if nowhere:
    bad("%d flow(s) have no destination: %s -- `send()` on an unconnected "
        "socket reaches udp_sendmsg before failing with EDESTADDRREQ, and no "
        "packet leaves" % (len(nowhere), [(e.get("comm"), e.get("dst")) for e in nowhere]))
else:
    ok("a send with no destination produces no flow")
nosend = [e for e in flows if e.get("proto") == "udp" and e.get("dport") == 7777]
if nosend:
    bad("a UDP socket that connected and never sent produced %d flow(s): the "
        "connect is not a packet" % len(nosend))
else:
    ok("and a connect with no send produces nothing at all")
for tool, port in (("dig", 53), ("nc", 53)):
    if wpid(tool):
        expect(tool, "%s over UDP" % tool, kind="net_flow", proto="udp",
               dst=DEST, dport=port)

print("  --- IPv6 ---------------------------------------------------------")
if HAVE_V6:
    expect("tcp6", "TCP over IPv6", kind="net_flow", proto="tcp", dst=DEST6)
    v6 = [e for e in flows if e.get("family") == 10]
    if v6:
        ok("family 10 (AF_INET6) on %d flow(s)" % len(v6))
    else:
        bad("no flow reported family 10")
else:
    print("  SKIP IPv6 was not exercised: this VM has no route to %s" % DEST6)

print("  --- one event per flow, never one per packet ----------------------")
icmp_by_pid = {}
for e in flows:
    if e.get("comm") == "ping" and e.get("proto") == "icmp":
        icmp_by_pid.setdefault(e["pid"], []).append(e)
if icmp_by_pid:
    ok("ping ICMP flows: %s" % {p: [x.get("count") for x in v]
                                for p, v in icmp_by_pid.items()})
    multiple = {p: len(v) for p, v in icmp_by_pid.items() if len(v) > 1}
    if multiple:
        bad("a single pid produced more than one ICMP flow to one destination "
            "(%s) -- that is per-packet, not per-flow" % multiple)
    else:
        ok("one ICMP flow per ping process, however many packets it sent")
    folded = max(max(x.get("count", 1) for x in v) for v in icmp_by_pid.values())
    if folded >= 5:
        ok("the 5-packet ping folded into one event with count %d" % folded)
    else:
        bad("no ping event folded 5 packets (max count %d); either the burst "
            "did not run or folding is not happening" % folded)
else:
    bad("no ICMP flow from `ping` at all")

print("  --- loopback is counted, not emitted -----------------------------")
exempt = {int(os.environ["PROXY_TEST_PORT"]),
           int(os.environ["REAL_PROXY_PORT"])}
loop = [e for e in flows
        if (str(e.get("dst", "")).startswith("127.") or e.get("dst") == "::1")
        and e.get("dport") not in exempt]
if loop:
    bad("%d loopback flow(s) were emitted; they can never carry a switch "
        "decision and they are the bulk of the volume" % len(loop))
else:
    ok("no loopback flow was emitted")
suppressed = [b["flows"]["local_suppressed"] for b in beats
              if isinstance(b.get("flows"), dict)]
if not suppressed:
    bad("heartbeats carry no flows.local_suppressed count")
elif suppressed[-1] > 0:
    ok("the heartbeat counts %d suppressed loopback flow(s) -- the decision "
       "not to report them is visible, not inferred from an absence"
       % suppressed[-1])
else:
    bad("local_suppressed is 0, but 20 loopback sends were driven")

print("  --- exec: argv and start_ns --------------------------------------")
marked = [e for e in execs if "bromure-argv-marker" in (e.get("argv") or "")]
if marked:
    ok("exec argv: %r" % marked[0]["argv"][:70])
    if marked[0]["argv"].count("  ") == 0 and " alpha beta gamma" in marked[0]["argv"]:
        ok("argv args are joined by single spaces, as the contract says")
    else:
        bad("argv joining is wrong: %r" % marked[0]["argv"])
else:
    bad("no exec event carried the argv marker; argv is not being read")
long_argv = [e for e in execs if "bromure-argv-long" in (e.get("argv") or "")]
if long_argv:
    e = long_argv[0]
    if len(e["argv"]) <= 1024:
        ok("a long argv is capped at %d bytes" % len(e["argv"]))
    else:
        bad("argv is %d bytes, over the 1024 cap" % len(e["argv"]))
    if e.get("argv_truncated"):
        ok("argv_truncated is set on the one that was cut")
    else:
        bad("a >1024-byte command line was not flagged argv_truncated")
else:
    bad("the long-argv exec was not captured")
empty = [e for e in execs if "bromure-argv-empty" in (e.get("argv") or "")]
if empty:
    e = empty[0]
    if "tail-survived" in e["argv"]:
        ok("an empty argument does not end the argv walk: %r" % e["argv"][:60])
    else:
        bad("argv stopped at the empty argument: %r" % e["argv"])
    if e.get("argv_truncated"):
        bad("an empty argument was mistaken for a truncation")
    else:
        ok("and it is not flagged as truncated")
else:
    bad("the empty-argument exec was not captured")

no_argv = [e for e in execs if not e.get("argv")]
if execs and len(no_argv) == len(execs):
    bad("every exec has an empty argv -- it is being read from the wrong place")
elif execs:
    ok("%d of %d exec events carry an argv" % (len(execs) - len(no_argv), len(execs)))

print("  --- (pid, start_ns) is a usable identity -------------------------")
# start_boottime, in ns. /proc/<pid>/stat field 22 is the same instant in clock
# ticks. Comparing them is what proves the field is the process's start time and
# not, say, the time the event was built.
hz = os.sysconf("SC_CLK_TCK")
checked = 0
for e in events:
    if not e.get("start_ns") or not e.get("pid"):
        continue
    try:
        fields = open("/proc/%d/stat" % e["pid"]).read().rsplit(") ", 1)[1].split()
    except (OSError, IndexError):
        continue          # exited already, which is the common case here
    proc_s = int(fields[19]) / hz
    if abs(proc_s - e["start_ns"] / 1e9) < 1.0:
        checked += 1
    else:
        bad("pid %d: start_ns says %.2fs, /proc says %.2fs"
            % (e["pid"], e["start_ns"] / 1e9, proc_s))
    if checked >= 3:
        break
if checked:
    ok("start_ns agrees with /proc/<pid>/stat for %d still-live process(es)" % checked)
else:
    print("  note every process in the capture had already exited, so start_ns "
          "could not be cross-checked against /proc (it was still present on "
          "every event)")
if events and all(e.get("start_ns") for e in events):
    ok("start_ns is on every event, not only on net_flow")
elif events:
    bad("%d event(s) have no start_ns"
        % sum(1 for e in events if not e.get("start_ns")))

print("  --- the chain is nearest-first and has real depth ----------------")
outer, inner = wpid("nested"), wpid("nested_inner")
deep = [e for e in flows if inner and inner in chain_pids(e)]
if deep:
    pids = chain_pids(deep[0])
    ok("nested: chain %s" % [(a["pid"], a["comm"]) for a in deep[0]["chain"]])
    if pids[0] == inner:
        ok("nested: nearest first -- chain[0] is the immediate parent")
    else:
        bad("nested: chain[0] is %d, expected the immediate parent %d"
            % (pids[0], inner))
    if outer and outer in pids and pids.index(outer) > pids.index(inner):
        ok("nested: the outer shell appears further out than the inner one")
    elif outer:
        bad("nested: outer %d is not ordered after inner %d in %s"
            % (outer, inner, pids))
    if len(pids) >= 2:
        ok("nested: chain depth %d" % len(pids))
elif inner:
    bad("no flow names the nested inner shell %d" % inner)
over = [e for e in flows if len(e.get("chain") or []) > 8]
if over:
    bad("%d chain(s) longer than the contract's 8" % len(over))
else:
    ok("no chain exceeds 8 ancestors")

print("  ------------------------------------------------------------------")
sys.exit(1 if fails else 0)
PY
    [ $? -ne 0 ] && fails=$((fails + 1))
fi

# ----------------------------------------------------------------------- cost --
# What the contract asks for: ns per connect and per send on a busy workload.
# Measured against the SAME loop with the module unloaded, on this machine, so
# the number is the module's own cost and not the loop's.
say "cost"
cat > /tmp/netflow-cost.py <<'PY'
import socket, sys, time
N = 20000
def tcp():
    t = time.perf_counter()
    for _ in range(N):
        s = socket.socket(); s.setblocking(False)
        try: s.connect(("127.0.0.1", 9))
        except OSError: pass
        s.close()
    return time.perf_counter() - t
def udp():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    t = time.perf_counter()
    for _ in range(N):
        try: s.sendto(b"x", ("127.0.0.1", 9))
        except OSError: pass
    s.close()
    return time.perf_counter() - t
fn = tcp if sys.argv[1] == "tcp" else udp
print("%.6f %d" % (min(fn() for _ in range(3)), N))
PY
# Loopback, deliberately: it reaches every probe and every filter, and it is the
# tightest loop the kernel will run -- so the per-op delta is not hidden behind a
# network round trip the way a real destination would hide it. That makes this an
# UPPER bound on the real cost, which is the useful direction.
for mode in tcp udp; do
    read -r LOADED _ <<< "$(python3 /tmp/netflow-cost.py $mode)"
    sudo rmmod bromure_sentry 2>/dev/null
    read -r BARE N <<< "$(python3 /tmp/netflow-cost.py $mode)"
    sudo insmod "$SENTRY/bromure_sentry.ko" cid=1 port="$PORT" boot_id="$BOOT_ID" 2>/dev/null
    python3 -c "
l, b, n = $LOADED, $BARE, $N
print('  %-4s %8.0f ns/op without the module, %8.0f with  (%+.0f ns/op, %+.1f%%)'
      % ('$mode', b/n*1e9, l/n*1e9, (l-b)/n*1e9, (l/b-1)*100))"
done
echo "  note these are loopback ops with the loopback FILTER active, so the"
echo "       handler runs, classifies and is suppressed -- the cost of a probe"
echo "       hit without the fifo push. The emitted path adds one 1792-byte"
echo "       memset, the chain walk and a kfifo push, once per flow per 10 s."
rm -f /tmp/netflow-cost.py

# -------------------------------------------------------------------- verdict --
printf '\n'
if [ "$fails" -ne 0 ]; then
    printf 'NETWORK LINEAGE: %d FAILED\n' "$fails"
    exit 1
fi
if [ "$skips" -ne 0 ]; then
    printf 'NETWORK LINEAGE: the checks that RAN passed -- but %d were SKIPPED\n' "$skips"
    printf '  (listed above; usually a tool missing from the image or no IPv6 route)\n'
    exit 77
fi
printf 'NETWORK LINEAGE: all checks passed\n'
