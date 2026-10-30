#!/bin/bash
# setup-network.sh: the host side of Bromure AC's VM network on Linux. Run it once as root.
#
#   - Creates a persistent tap, owned by the user who runs bromure-ac. That user can then open it
#     without privileges; it is the switch's uplink, ACLinux's TapUplink.
#   - Gives the tap the host's address on the VM subnet. The default is 192.168.64.1/24, as the
#     macOS vmnet gateway.
#   - Adds an nftables table `ip bromure` that masquerades the subnet out of the uplink interface
#     and accepts that forwarded traffic in its own forward chain.
#   - Turns on net.ipv4.ip_forward (runtime only).
#
# It is idempotent: running it again converges, and the table is replaced atomically. It never
# touches other tables (Docker's included). The tap, address, table and sysctl last until reboot;
# re-run it from a boot unit to keep them.
#
# Usage: setup-network.sh [--user NAME] [--dev bromure0] [--subnet 192.168.64.1/24]
#                         [--uplink IFACE] [--uninstall]
set -euo pipefail

USER_NAME=${SUDO_USER:-}
DEV=bromure0
SUBNET=192.168.64.1/24
UPLINK=
UNINSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --user) USER_NAME=$2; shift 2 ;;
    --dev) DEV=$2; shift 2 ;;
    --subnet) SUBNET=$2; shift 2 ;;
    --uplink) UPLINK=$2; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "setup-network: unknown argument $1" >&2; exit 2 ;;
  esac
done
log() { echo "setup-network: $*"; }
die() { echo "setup-network: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"
command -v nft >/dev/null || die "nft (nftables) is required"

if [ $UNINSTALL = 1 ]; then
  nft list table ip bromure >/dev/null 2>&1 && nft delete table ip bromure && log "removed nftables table ip bromure"
  ip link show "$DEV" >/dev/null 2>&1 && ip tuntap del dev "$DEV" mode tap && log "removed tap $DEV"
  log "uninstalled (net.ipv4.ip_forward left as is: other software may rely on it)"
  exit 0
fi

[ -n "$USER_NAME" ] || die "--user is required (or run through sudo)"
UID_NUM=$(id -u "$USER_NAME") || die "no such user: $USER_NAME"

# Subnet: host address/prefix. The network must not overlap any route the host already has
# (Docker's bridges, the LAN, VPNs), except routes through our own tap.
python3 - "$SUBNET" "$DEV" <<'PY' || exit 1
import ipaddress, json, subprocess, sys
iface = ipaddress.ip_interface(sys.argv[1]); dev = sys.argv[2]
if iface.version != 4 or iface.network.prefixlen > 30 or iface.ip == iface.network.network_address:
    sys.exit("setup-network: --subnet must be an IPv4 host address with a /8../30 prefix, e.g. 192.168.64.1/24")
routes = json.loads(subprocess.run(["ip", "-j", "-4", "route", "show", "table", "all"],
                                   capture_output=True, text=True, check=True).stdout)
for r in routes:
    dst = r.get("dst")
    if not dst or dst == "default" or r.get("dev") == dev or r.get("type") in ("local", "broadcast"):
        continue
    try:
        net = ipaddress.ip_network(dst if "/" in dst else dst + "/32", strict=False)
    except ValueError:
        continue
    if net.overlaps(iface.network) and net.prefixlen > 0:
        sys.exit(f"setup-network: {iface.network} overlaps {net} on {r.get('dev')}; pick another --subnet")
PY
NET=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)' "$SUBNET")

# The uplink: the default route's interface, unless given.
if [ -z "$UPLINK" ]; then
  UPLINK=$(ip -4 route show default | awk '/default/ { for (i = 1; i < NF; i++) if ($i == "dev") { print $(i+1); exit } }')
  [ -n "$UPLINK" ] || die "no IPv4 default route; pass --uplink IFACE"
fi
[ "$UPLINK" != "$DEV" ] || die "the uplink can't be $DEV itself"

# Tap: persistent, owned by the user. An existing one must belong to the same user.
if ip link show "$DEV" >/dev/null 2>&1; then
  owner=$(cat "/sys/class/net/$DEV/owner" 2>/dev/null || echo "")
  [ "$owner" = "$UID_NUM" ] || die "$DEV exists but isn't a tap owned by $USER_NAME (owner '$owner'); remove it or pick --dev"
else
  ip tuntap add dev "$DEV" mode tap user "$UID_NUM"
  log "created tap $DEV owned by $USER_NAME"
fi
ip addr flush dev "$DEV" scope global
ip addr add "$SUBNET" dev "$DEV"
ip link set "$DEV" up
sysctl -q -w net.ipv4.ip_forward=1

# One transaction: create-if-missing, delete, recreate, so a re-run swaps it atomically.
nft -f - <<NFT
table ip bromure {}
delete table ip bromure
table ip bromure {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr $NET oifname "$UPLINK" masquerade
  }
  chain forward {
    type filter hook forward priority filter; policy accept;
    iifname "$DEV" oifname "$UPLINK" ip saddr $NET accept
    iifname "$UPLINK" oifname "$DEV" ct state established,related accept
  }
}
NFT
log "$DEV = $SUBNET, masquerading $NET out of $UPLINK (nftables table ip bromure)"

# Another table's forward chain with policy drop still drops what ours accepts: nftables runs
# every base chain on the hook. Docker installs exactly that. Report it; don't touch it.
if nft list chain ip filter FORWARD 2>/dev/null | grep -q 'policy drop'; then
  log "WARNING: table ip filter (Docker's) has a FORWARD policy of drop. VM traffic forwarded out"
  log "         of $UPLINK will be dropped there unless allowed in its DOCKER-USER chain, e.g.:"
  log "           iptables -I DOCKER-USER -i $DEV -o $UPLINK -s $NET -j ACCEPT"
  log "           iptables -I DOCKER-USER -i $UPLINK -o $DEV -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
fi
