#!/bin/bash
# test-network.sh: run as root (sudo). Exercises setup-network.sh and the stream-port/tap bridge
# inside throwaway network namespaces; nothing in the host's own namespace changes.
#
#   bromure-ci-wan   10.99.0.1, a stand-in for the internet: a UDP :53 listener that logs who asks
#        | veth
#   bromure-ci-host  10.99.0.2 (default route via .1), plus setup-network.sh's bromure0 (192.168.64.1/24)
#                    and its masquerade. The KVM test runs here as the invoking user (group kvm):
#                    the guest gets 192.168.64.2 from the test's DHCP, is pinged from the host side,
#                    and its resolver's queries must reach the wan side.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
RUN_AS=${SUDO_USER:?run through sudo, as the user who owns the build}
HOST=bromure-ci-host WAN=bromure-ci-wan
W=$(mktemp -d /tmp/bromure-ci-net.XXXXXX); chmod 755 "$W"
cleanup() {
  [ -f "$W/dns.pid" ] && kill "$(cat "$W/dns.pid")" 2>/dev/null || true
  ip netns del $HOST 2>/dev/null || true
  ip netns del $WAN 2>/dev/null || true
  rm -rf "$W"
}
trap cleanup EXIT
cleanup; mkdir -p "$W"; chmod 755 "$W"
step() { printf '\n-- %s\n' "$*"; }

step "namespaces"
ip netns add $HOST; ip netns add $WAN
ip link add up0 netns $HOST type veth peer name wan0 netns $WAN
ip -n $WAN addr add 10.99.0.1/24 dev wan0; ip -n $WAN link set wan0 up; ip -n $WAN link set lo up
ip -n $HOST addr add 10.99.0.2/24 dev up0; ip -n $HOST link set up0 up; ip -n $HOST link set lo up
ip -n $HOST route add default via 10.99.0.1
# Unprivileged ping inside the namespace (ICMP datagram sockets).
ip netns exec $HOST sysctl -q -w net.ipv4.ping_group_range="0 2147483647"

step "setup-network.sh: install twice, then a Docker-style drop policy is reported"
S="$ROOT/linux/setup-network.sh"
ip netns exec $HOST "$S" --user "$RUN_AS"
ip netns exec $HOST "$S" --user "$RUN_AS"
ip netns exec $HOST nft list table ip bromure | grep -q 'oifname "up0" masquerade'
ip netns exec $HOST nft -f - <<'NFT'
table ip filter {
  chain FORWARD {
    type filter hook forward priority filter; policy drop;
  }
}
NFT
ip netns exec $HOST "$S" --user "$RUN_AS" | grep -q 'WARNING: table ip filter'
echo "drop-policy warning: ok"
ip netns exec $HOST nft delete table ip filter

step "the far side: DNS listener on 10.99.0.1:53"
: > "$W/wan.log"; chmod 644 "$W/wan.log"
ip netns exec $WAN python3 -I -c '
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("10.99.0.1", 53))
log = open(sys.argv[1], "a", buffering=1)
while True:
    d, (ip, port) = s.recvfrom(4096)
    name, i = [], 12
    while i < len(d) and d[i]:
        name.append(d[i+1:i+1+d[i]].decode(errors="replace")); i += 1 + d[i]
    log.write("%s:%d asked %s\n" % (ip, port, ".".join(name)))
' "$W/wan.log" & echo $! > "$W/dns.pid"

step "bridge test (KVM, as $RUN_AS)"
HOME_DIR=$(getent passwd "$RUN_AS" | cut -d: -f6)
ip netns exec $HOST sudo -u "$RUN_AS" -g kvm env HOME="$HOME_DIR" PATH="$HOME_DIR/.local/share/swiftly/bin:$PATH" \
  BROMURE_NET_TEST=1 BROMURE_TEST_DNS=10.99.0.1 BROMURE_WAN_LOG="$W/wan.log" \
  swift test --package-path "$ROOT/linux/ACLinux" --filter BridgeTests
echo "wan side saw:"; sort -u "$W/wan.log" | head -5

step "setup-network.sh --uninstall, twice"
ip netns exec $HOST "$S" --uninstall
ip netns exec $HOST "$S" --uninstall
! ip netns exec $HOST ip link show bromure0 >/dev/null 2>&1
! ip netns exec $HOST nft list table ip bromure >/dev/null 2>&1
echo "network test: ok"
