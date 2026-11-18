#!/bin/bash
# linux/multiuser/configure.sh [--bind ADDR] [--port N] [--units DIR] [--bin PATH]:
# the multi-user Bromure server's system side (root), once its files are in
# place: the gateway's and the LAN helper's accounts, the state directories,
# arp_notify on the LAN interface, the gateway's and P2P's config (an
# existing one is kept), the units, then the gateway and the LAN helper
# (re)started. Run by install.sh (a source install) and by the Debian
# package's postinst. --units: copy the units from DIR into
# /etc/systemd/system (install.sh; the package ships them in
# /usr/lib/systemd/system). --bin: the installed bromure-ac (for the
# closing status line).
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "configure.sh: run as root (sudo)" >&2; exit 1; }
BIND=0.0.0.0; PORT=2222; UNITS=; BIN=/usr/local/bin/bromure-ac
while [ $# -gt 0 ]; do
  case $1 in
    --bind) BIND=$2; shift 2;;
    --port) PORT=$2; shift 2;;
    --units) UNITS=$2; shift 2;;
    --bin) BIN=$2; shift 2;;
    *) echo "configure.sh: unknown $1" >&2; exit 2;;
  esac
done

install -d -m 755 /var/lib/bromure-ac /run/bromure-ac/sock

getent group bromure >/dev/null || groupadd --system bromure
getent passwd bromure >/dev/null || useradd --system --gid bromure --no-create-home --home-dir /var/lib/bromure-gw \
  --shell /usr/sbin/nologin --comment "Bromure SSH gateway" bromure

# The LAN address helper (bromure-lan.service) and its pools file. A user's
# granted address (bromure-ac admin pool add) is one of this server's own
# while a Service is published on it: anything listening on 0.0.0.0 here
# (sshd, the gateway…) answers on it too, as it does on the server's own LAN
# address. arp_notify announces an address the moment it's added.
getent group bromure-lan >/dev/null || groupadd --system bromure-lan
getent passwd bromure-lan >/dev/null || useradd --system --gid bromure-lan --no-create-home --home-dir /nonexistent \
  --shell /usr/sbin/nologin --comment "Bromure LAN address helper" bromure-lan
install -d -m 755 /etc/bromure-ac
[ -e /etc/bromure-ac/lan-pools.json ] || { echo '{"grants": {}}' > /etc/bromure-ac/lan-pools.json; chmod 644 /etc/bromure-ac/lan-pools.json; }
LANIF=$(python3 -c 'import json; print(json.load(open("/etc/bromure-ac/lan-pools.json")).get("interface") or "")')
[ -n "$LANIF" ] || LANIF=$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
# The name goes into a sysctl path: the same rule as bromure-ac's (LANRoute.validInterfaceName).
case "$LANIF" in -*|.|..|*[!A-Za-z0-9_.:-]*) echo "configure.sh: '$LANIF' isn't an interface name" >&2; exit 1;; esac
[ ${#LANIF} -le 15 ] || { echo "configure.sh: '$LANIF' is longer than 15 characters" >&2; exit 1; }
[ -n "$LANIF" ] && { echo "net.ipv4.conf.$LANIF.arp_notify = 1" > /etc/sysctl.d/60-bromure-lan.conf; sysctl -q -p /etc/sysctl.d/60-bromure-lan.conf; }

if [ -n "$UNITS" ]; then
  install -m 644 "$UNITS/bromure-ac@.service" "$UNITS/bromure-ac@.socket" "$UNITS/bromure-gw.service" \
    "$UNITS/bromure-gw-p2p.socket" "$UNITS/bromure-lan.service" /etc/systemd/system/
fi
install -d -m 700 -o bromure -g bromure /var/lib/bromure-gw
[ -e /var/lib/bromure-gw/gateway.json ] || { printf '{"port": %s, "bindAddress": "%s", "codeLogin": true, "socketDir": "/run/bromure-ac/sock"}\n' "$PORT" "$BIND" > /var/lib/bromure-gw/gateway.json; chown bromure:bromure /var/lib/bromure-gw/gateway.json; chmod 600 /var/lib/bromure-gw/gateway.json; }
# P2P is on by default, users' ports on the gateway's address (as `bromure-ac
# admin p2p on` sets it); the admin's own choice (`admin p2p off`) is kept.
if [ ! -e /etc/bromure-ac/p2p.json ]; then
  GWBIND=$(python3 -c 'import json; print(json.load(open("/var/lib/bromure-gw/gateway.json")).get("bindAddress") or "0.0.0.0")')
  printf '{"bindAddress": "%s", "enabled": true}\n' "$GWBIND" > /etc/bromure-ac/p2p.json.new && chmod 644 /etc/bromure-ac/p2p.json.new \
    && mv -f /etc/bromure-ac/p2p.json.new /etc/bromure-ac/p2p.json
fi
systemctl daemon-reload
# The socket's service mustn't be running when it starts (systemd refuses:
# an earlier install's gateway, which had no socket): stopped first, started
# again below.
systemctl is-active --quiet bromure-gw-p2p.socket || systemctl stop bromure-gw.service
systemctl enable --now bromure-gw-p2p.socket
systemctl enable --now bromure-gw.service bromure-lan.service
systemctl restart bromure-gw.service bromure-lan.service
echo "installed; gateway: $(systemctl is-active bromure-gw.service), LAN helper: $(systemctl is-active bromure-lan.service), $("$BIN" admin p2p). Add users: bromure-ac admin add <name>; their LAN pools: bromure-ac admin pool add <name> <range>"
