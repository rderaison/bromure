#!/usr/bin/env bash
# The container mark: an unforgeable label on container traffic.
#
# The host can offer "don't intercept container traffic" only if it can tell a
# container's packets from the guest's own, and every label the guest could set
# -- an alias IP, a port range, an iptables mark -- is forgeable by root. The
# sentry applies this one from a netfilter hook, outside iptables, in a module
# lockdown keeps loaded.
#
# Needs the module LOADED, so it skips loudly where lockdown forbids that.
# Needs Docker, which is on the base image. Does NOT need tcpdump, which is
# not: DSCP is the top 6 bits of byte 1 of the IPv4 header and an AF_PACKET
# socket can read it.
#
# Run: tests/test_container_mark.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
SENTRY="$ROOT/sentry"
PORT=${PORT:-5841}
DEST=${DEST:-1.1.1.1}
MARK=43
fails=0
skips=0

say()  { printf '\n=== %s ===\n' "$1"; }
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }
skip() { printf '  SKIP %s\n' "$1"; skips=$((skips + 1)); }

# Discovered, not hardcoded: this image's egress interface is `enp0s1`, not
# `eth0`, and a test that assumes the name passes vacuously on the wrong one.
IFACE=$(ip route get "$DEST" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
FRAMES=$(mktemp /tmp/cmark-frames-XXXXXX.json)
SNIFF=$(mktemp /tmp/cmark-sniff-XXXXXX.py)

cleanup() {
    # The writers first, then the state they write -- a cleanup that restores
    # before stopping the thing that changes it restores nothing.
    sudo rmmod bromure_sentry 2>/dev/null
    sudo iptables -t mangle -D POSTROUTING -j DSCP --set-dscp $MARK 2>/dev/null
    sudo iptables -D FORWARD -i cmarktun0 -j ACCEPT 2>/dev/null
    sudo iptables -t nat -D POSTROUTING -s 10.78.0.0/24 -o "$IFACE" -j MASQUERADE 2>/dev/null
    sudo tc qdisc del dev lo root 2>/dev/null
    sudo ip link del cmarktun0 2>/dev/null
    rm -f "$FRAMES" "$SNIFF" /tmp/cmark-*.txt
}
trap cleanup EXIT

say "preflight"
LOCKDOWN=$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/kernel/security/lockdown 2>/dev/null)
if [ -n "$LOCKDOWN" ] && [ "$LOCKDOWN" != "none" ]; then
    printf '\n  SKIPPED: lockdown=%s refuses unsigned modules, and this suite\n' "$LOCKDOWN"
    printf '           must LOAD the sentry to test its netfilter hook.\n'
    printf '\n  THE CONTAINER MARK SUITE DID NOT RUN.\n\n'
    exit 77
fi
ok "lockdown=none"
if ! command -v docker > /dev/null 2>&1 || ! sudo docker info > /dev/null 2>&1; then
    printf '\n  SKIPPED: docker is not usable; every container case needs it.\n'
    printf '\n  THE CONTAINER MARK SUITE DID NOT RUN.\n\n'
    exit 77
fi
ok "docker is usable"
[ -n "$IFACE" ] && ok "egress interface: $IFACE" || { bad "no route to $DEST"; exit 1; }
if ! sudo docker image inspect alpine > /dev/null 2>&1; then
    sudo docker pull -q alpine > /dev/null 2>&1 || { skip "no alpine image and no pull"; }
fi

cat > "$SNIFF" <<'PY'
import socket, struct, sys, time
iface, want, seconds = sys.argv[1], sys.argv[2], float(sys.argv[3])
s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(3))
s.bind((iface, 0)); s.settimeout(0.3)
seen, end = {}, time.time() + seconds
while time.time() < end:
    try: f = s.recv(65535)
    except socket.timeout: continue
    if len(f) < 34: continue
    et = struct.unpack("!H", f[12:14])[0]
    if et == 0x0800:
        ip = f[14:]; tos = ip[1]; dst = socket.inet_ntoa(ip[16:20]); src = socket.inet_ntoa(ip[12:16])
    elif et == 0x86DD:
        ip = f[14:]; tos = ((ip[0] & 0x0F) << 4) | ((ip[1] & 0xF0) >> 4)
        dst = socket.inet_ntop(socket.AF_INET6, ip[24:40]); src = socket.inet_ntop(socket.AF_INET6, ip[8:24])
    else: continue
    if want not in (dst, "any"): continue
    k = (src, dst, tos >> 2); seen[k] = seen.get(k, 0) + 1
for (src, dst, dscp), n in sorted(seen.items(), key=lambda kv: -kv[1]):
    print("%s %s %d %d" % (src, dst, dscp, n))
PY

say "load"
sudo modprobe vsock_loopback 2>/dev/null
sudo rmmod bromure_sentry 2>/dev/null
make -C "$SENTRY" clean > /dev/null 2>&1
make -C "$SENTRY" EXTRA_CFLAGS=-DBROMURE_SENTRY_TESTABLE > /tmp/cmark-build.log 2>&1 \
    || { bad "build (see /tmp/cmark-build.log)"; exit 1; }
python3 "$HERE/vsock_sink.py" --port "$PORT" --seconds 75 --json-out "$FRAMES" \
    > /tmp/cmark-sink.log 2>&1 &
SINKPID=$!
sleep 1
sudo insmod "$SENTRY/bromure_sentry.ko" cid=1 port="$PORT" \
    boot_id="$(cat /proc/sys/kernel/random/boot_id)" || { bad "insmod"; exit 1; }
echo 1 | sudo tee /sys/module/bromure_sentry/parameters/phase > /dev/null
ok "loaded, phase=session"
if sudo dmesg | tail -20 | grep -q "marking forwarded traffic DSCP $MARK"; then
    ok "the hook registered (dmesg says so)"
else
    bad "no 'marking forwarded traffic' line: the netfilter hook did not register"
fi

# dscp <desc> <expected-dscp> <command…>
dscp_of() {
    local desc="$1" want="$2"; shift 2
    sudo python3 "$SNIFF" "$IFACE" "$DEST" 8 > /tmp/cmark-cap.txt 2>&1 &
    local sp=$!; sleep 1; eval "$@" > /dev/null 2>&1; wait $sp
    local got
    got=$(awk -v d="$DEST" '$2==d {print $3}' /tmp/cmark-cap.txt | sort -u | tr '\n' ',' )
    if [ "$got" = "$want," ]; then
        ok "$desc -> DSCP $want"
    elif [ -z "$got" ]; then
        skip "$desc -> no packets captured (no egress to $DEST?)"
    else
        bad "$desc -> DSCP {$got} expected $want"
    fi
}

say "the mark itself"
dscp_of "a container's traffic" "$MARK" "sudo docker run --rm alpine ping -c3 -W2 $DEST"
dscp_of "the guest's own traffic" 0 "curl -s -m4 --noproxy '*' -o /dev/null https://$DEST/"

say "forgery"
dscp_of "a process setting IP_TOS=0xAC itself" 0 "sudo python3 -c \"
import socket
s = socket.socket(); s.setsockopt(socket.IPPROTO_IP, socket.IP_TOS, $((MARK * 4)))
s.settimeout(3)
try: s.connect(('$DEST', 443))
except OSError: pass
\""
# The hole that made the first design wrong: LOCAL_OUT runs BEFORE POSTROUTING,
# so a mangle POSTROUTING rule ran after it. The hook is on POSTROUTING at
# NF_IP_PRI_LAST now, which is after nat and after every iptables rule.
sudo iptables -t mangle -A POSTROUTING -j DSCP --set-dscp $MARK
dscp_of "root's mangle POSTROUTING rule on the guest's traffic" 0 \
    "curl -s -m4 --noproxy '*' -o /dev/null https://$DEST/"
sudo iptables -t mangle -D POSTROUTING -j DSCP --set-dscp $MARK

say "a tun is not a container"
# Root can make a tun, route traffic into it and write packets back, and they
# arrive with a non-zero skb_iif -- "forwarded" by any naive test. The device
# TYPE check is what rejects them. Docker's FORWARD policy is DROP, so the
# packets have to be explicitly permitted or they never reach POSTROUTING and
# the test proves nothing (measured: it silently proved nothing at first).
TUN_BEFORE_MARKED=$(sudo cat /sys/module/bromure_sentry/parameters/phase > /dev/null; echo 0)
sudo ip tuntap add mode tun name cmarktun0 2>/dev/null
sudo ip addr add 10.78.0.1/24 dev cmarktun0 2>/dev/null
sudo ip link set cmarktun0 up
sudo sysctl -qw net.ipv4.conf.cmarktun0.rp_filter=0 2>/dev/null
sudo iptables -I FORWARD 1 -i cmarktun0 -j ACCEPT
sudo iptables -t nat -I POSTROUTING 1 -s 10.78.0.0/24 -o "$IFACE" -j MASQUERADE
sudo python3 - <<PY > /tmp/cmark-tun.txt 2>&1
import fcntl, os, socket, struct, time
tun = os.open("/dev/net/tun", os.O_RDWR)
fcntl.ioctl(tun, 0x400454ca, struct.pack("16sH", b"cmarktun0", 0x0001 | 0x1000))
def pkt(tos):
    def mk(c):
        return struct.pack("!BBHHHBBH4s4s", 0x45, tos, 28, 0x1234, 0, 64, 1, c,
                           socket.inet_aton("10.78.0.9"), socket.inet_aton("$DEST"))
    w = struct.unpack("!10H", mk(0)); c = sum(w)
    c = (c >> 16) + (c & 0xffff); c = (~c) & 0xffff
    return mk(c) + struct.pack("!BBHHH", 8, 0, 0xf7ff, 0x4242, 1)
p = pkt($MARK << 2)
for _ in range(6):
    try: os.write(tun, p)
    except OSError: pass
    time.sleep(0.15)
time.sleep(1)
os.close(tun)
print("injected 6 marked packets via the tun")
PY
sed 's/^/     /' /tmp/cmark-tun.txt
sudo iptables -D FORWARD -i cmarktun0 -j ACCEPT 2>/dev/null
sudo iptables -t nat -D POSTROUTING -s 10.78.0.0/24 -o "$IFACE" -j MASQUERADE 2>/dev/null
sudo ip link del cmarktun0 2>/dev/null
ok "tun torn down"

say "tc: detected, because it cannot be prevented"
# An egress qdisc action runs inside __dev_queue_xmit, after netfilter, so no
# hook the sentry can take is later. Measured: a pedit filter stamps the mark
# on local traffic and the POSTROUTING hook cannot undo it. So the sentry
# REPORTS it and the host revokes the exemption. `lo` is used, not the egress
# interface -- a qdisc on the real one would be a live-traffic hazard.
sudo tc qdisc add dev lo root handle 1: prio > /dev/null 2>&1 && ok "tc qdisc add ran"
sudo tc filter add dev lo parent 1: protocol ip prio 1 u32 \
    match ip dst 127.0.0.9/32 action pedit ex munge ip dsfield set 0xac \
    > /dev/null 2>&1 && ok "tc filter add ran"
sudo tc qdisc del dev lo root > /dev/null 2>&1
say "docker must NOT look like tampering"
sudo docker run --rm alpine true > /dev/null 2>&1 && ok "docker run completed"
sudo docker network create cmark-probe > /dev/null 2>&1
sudo docker run --rm --network cmark-probe alpine true > /dev/null 2>&1
sudo docker network rm cmark-probe > /dev/null 2>&1
ok "docker network create + container + rm completed"

say "what the sentry reported"
wait "$SINKPID" 2>/dev/null
if [ ! -s "$FRAMES" ]; then
    bad "no frames captured"
else
    MARKV="$MARK" python3 - "$FRAMES" <<'PY'
import json, os, sys
fr = json.load(open(sys.argv[1]))
MARK = int(os.environ["MARKV"])
fails = 0
def ok(m): print("  ok   %s" % m)
def bad(m):
    global fails
    print("  FAIL %s" % m); fails += 1

hello = next((f for f in fr if f.get("type") == "hello"), {})
if hello.get("container_mark") == MARK:
    ok("the hello announces container_mark: %d -- the host will not trust a "
       "mark this module did not claim" % MARK)
else:
    bad("hello container_mark is %r, expected %d" % (hello.get("container_mark"), MARK))
probes = hello.get("probes") or []
missing = [p for p in ("tc_modify_qdisc", "tc_new_tfilter", "tc_ctl_action")
           if p not in probes]
if missing:
    bad("tc probes absent from the hello: %s -- the host would read their "
        "silence as 'no tampering'" % missing)
else:
    ok("all three tc probes are in the hello's probe list")

hb = [f for f in fr if f.get("type") == "heartbeat"
      and isinstance(f.get("containers"), dict)]
if not hb:
    bad("no heartbeat carried the containers counters")
else:
    c = hb[-1]["containers"]
    ok("counters: %s" % json.dumps(c))
    if c.get("marked", 0) > 0:
        ok("marked > 0: container packets were stamped")
    else:
        bad("marked is 0, so no container traffic was ever marked")
    if c.get("forged_cleared", 0) > 0:
        ok("forged_cleared > 0: forged marks were stripped")
    else:
        bad("forged_cleared is 0, though forgeries were driven")

forged = [f for f in fr if f.get("kind") == "container_mark_forged"]
# The accusation requires the SOCKET's own IP_TOS. Without that rule, one
# root-added mangle rule made every process on the box look guilty -- measured:
# 36 clearings and events naming curl and the coding agent, neither of which
# had touched IP_TOS.
accused = {f.get("comm") for f in forged}
if forged:
    ok("%d forgery event(s), accusing: %s" % (len(forged), sorted(accused)))
else:
    bad("no container_mark_forged event, though a process set IP_TOS itself")
innocent = accused & {"curl", "claude", "node"}
if innocent:
    bad("processes accused that never set IP_TOS: %s -- the accusation must "
        "require the socket's own TOS, or a global iptables rule blames "
        "everyone" % sorted(innocent))
else:
    ok("no process accused for a rule's doing (curl/agent not named)")

tc = [f for f in fr if f.get("kind") == "tc_change"]
ops = sorted(f.get("op") for f in tc)
if "qdisc" in ops and "filter" in ops:
    ok("tc_change events: %s" % [(f.get("op"), f.get("dev"), f.get("tc_kind"))
                                 for f in tc])
else:
    bad("tc_change ops were %s, expected at least qdisc and filter" % ops)
for f in tc:
    if f.get("op") in ("qdisc", "filter") and not f.get("dev"):
        bad("a %s tc_change carries no dev; the host cannot say which "
            "interface" % f.get("op"))
        break
else:
    if tc:
        ok("every qdisc/filter tc_change names its interface")
by_tc = [f for f in tc if f.get("comm") == "tc"]
if len(by_tc) == len(tc) and tc:
    ok("every tc_change was attributed to the tc process, none to docker")
elif tc:
    bad("tc_change attributed to something other than tc: %s"
        % sorted({f.get("comm") for f in tc}))
if len(tc) > 2:
    bad("%d tc_change events for 2 tc commands: docker activity is being "
        "reported as tampering, and the host revokes on this" % len(tc))
else:
    ok("exactly %d tc_change events for the 2 tc commands -- docker produced "
       "none" % len(tc))
sys.exit(1 if fails else 0)
PY
    [ $? -ne 0 ] && fails=$((fails + 1))
fi

say "agentd honours the containers-direct marker"
ROOT="$ROOT" python3 - <<'PYEOF'
import importlib.machinery, importlib.util, os, sys, tempfile
meta = tempfile.mkdtemp()
os.environ["BROMURE_META"] = meta
loader = importlib.machinery.SourceFileLoader(
    "ad", os.environ["ROOT"] + "/patched/bromure-agentd.py")
spec = importlib.util.spec_from_loader("ad", loader)
ad = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ad)
fails = 0
def ok(m): print("  ok   %s" % m)
def bad(m):
    global fails
    print("  FAIL %s" % m); fails += 1

if ad.containers_direct():
    bad("containers_direct() is true with no marker staged")
else:
    ok("no marker: containers_direct() is false, nothing changes")
open(os.path.join(meta, "containers-direct"), "w").close()
if ad.containers_direct():
    ok("marker staged: containers_direct() is true")
else:
    bad("the marker is present but containers_direct() is false")

def names(direct):
    out = []
    for ln in ad._PROXY_ENV_LINES:
        if direct and ln.split("=", 1)[0].lower() in (
                "http_proxy", "https_proxy", "no_proxy"):
            continue
        out.append(ln.split("=", 1)[0])
    return out
off, on = names(False), names(True)
withheld = [v for v in off if v not in on]
if withheld and all("PROXY" in v.upper() for v in withheld):
    ok("only proxy variables are withheld (%d of them)" % len(withheld))
else:
    bad("withheld set is wrong: %s" % withheld)
kept_ca = [v for v in on if "CA" in v.upper() or "SSL" in v.upper()]
if kept_ca:
    ok("the CA/SSL variables are kept (%d), so an image expecting the bundle "
       "still works" % len(kept_ca))
else:
    bad("CA/SSL variables were withheld too; only the proxy should be")

# dockerd's OWN proxy must survive: image pulls stay inspected, which is what
# keeps the supply-chain checks working while container traffic goes direct.
frag = ad._docker_proxy_fragment()
if "HTTP_PROXY=http://127.0.0.1" in frag:
    ok("dockerd's own proxy drop-in is unchanged -- image pulls stay inspected")
else:
    bad("dockerd's proxy drop-in lost its proxy: %r" % frag[:120])
sys.exit(1 if fails else 0)
PYEOF
rc=$?; [ $rc -eq 0 ] || { fails=$((fails + 1)); printf "  FAIL the block above exited %s\n" "$rc"; }

printf '\n'
if [ "$fails" -ne 0 ]; then
    printf 'CONTAINER MARK: %d FAILED\n' "$fails"; exit 1
fi
if [ "$skips" -ne 0 ]; then
    printf 'CONTAINER MARK: the checks that RAN passed -- %d SKIPPED (above)\n' "$skips"
    exit 77
fi
printf 'CONTAINER MARK: all checks passed\n'
