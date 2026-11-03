#!/bin/bash
# test-multiuser.sh: two throwaway Bromure users on an installed multi-user
# server (install.sh), through the gateway; removes them at the end.
# Needs passwordless sudo. HOST/PORT default to the gateway.json's.
set -u
A=${A:-bru-a}; B=${B:-bru-b}
GWCONF=$(sudo -n cat /var/lib/bromure-gw/gateway.json)
HOST=${HOST:-$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['bindAddress'])" "$GWCONF")}
PORT=${PORT:-$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['port'])" "$GWCONF")}
[ "$HOST" = 0.0.0.0 ] && HOST=127.0.0.1
W=$(mktemp -d); pass=0; fail=0
ok() { echo "PASS $*"; pass=$((pass + 1)); }
no() { echo "FAIL $*"; fail=$((fail + 1)); }
cleanup() { for u in $A $B; do sudo -n bromure-ac admin remove $u --purge --delete-account >/dev/null 2>&1; done; rm -rf "$W"; }
trap cleanup EXIT
SSHO=(-p $PORT -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$W/known_hosts -o LogLevel=ERROR -o ConnectTimeout=10)
req() { printf '%s %s HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' "$1" "$2" ${#3} "$3"; }
# as USER KEY METHOD PATH [BODY]: one request through the gateway; the JSON body.
as() { req "$3" "$4" "${5:-}" | timeout 60 ssh "${SSHO[@]}" -i "$2" -o IdentitiesOnly=yes -o PreferredAuthentications=publickey \
       "$1@$HOST" 'bromure-fatclient/1 control' 2>/dev/null | sed -n '/^{/,$p'; }
for u in $A $B; do
  sudo -n bromure-ac admin add $u >/dev/null || { no "admin add $u"; exit 1; }
  ssh-keygen -q -t ed25519 -N '' -C "$u-key" -f $W/$u
done
ok "admin add $A $B"
# A enrolls its key with a one-time code over the gateway; B's goes in as root.
CODE=$(sudo -n bromure-ac admin code $A --minutes 2 | sed -n 's/.*: //p')
printf '#!/bin/sh\necho %s\n' "$CODE" > $W/askpass; chmod 700 $W/askpass
R=$(req POST /remote/keys "{\"key\":\"$(cat $W/$A.pub)\"}" | SSH_ASKPASS=$W/askpass SSH_ASKPASS_REQUIRE=force DISPLAY=x timeout 30 \
    ssh "${SSHO[@]}" -o PreferredAuthentications=password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 "$A@$HOST" 'bromure-fatclient/1 control' 2>/dev/null)
echo "$R" | grep -q '"ok" : true' && ok "$A enrolled its key with a code over the gateway" || no "$A code enrollment: $R"
echo | SSH_ASKPASS=$W/askpass SSH_ASKPASS_REQUIRE=force DISPLAY=x timeout 30 ssh "${SSHO[@]}" -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 "$B@$HOST" 'bromure-fatclient/1 control' >/dev/null 2>&1 \
  && no "$A's code opened $B" || ok "a used code doesn't open $B"
BODY="{\"key\":\"$(cat $W/$B.pub)\"}"
printf 'POST /remote/keys HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n%s' ${#BODY} "$BODY" > $W/breq
sudo -n python3 -c "
import socket; s=socket.socket(socket.AF_UNIX); s.connect('/run/bromure-ac/sock/$B.sock'); s.sendall(open('$W/breq','rb').read()); print(s.recv(65536).decode())" \
  | grep -q '"ok" : true' && ok "$B's key added (root, on its socket)" || no "$B key"
# Keys open only their own account; an unknown account fails the same way.
as $A $W/$A GET /health | grep -q '"status"' && ok "$A's key opens $A" || no "$A's key"
[ -z "$(as $B $W/$A GET /health)" ] && ok "$A's key doesn't open $B" || no "$A's key opened $B"
[ -z "$(as nobody-here $W/$A GET /health)" ] && ok "unknown account refused" || no "unknown account answered"
# Same VM name in both; each sees only its own.
for u in $A $B; do
  R=$(as $u $W/$u POST /vms '{"name":"same","machine":"firecracker"}')
  echo "$R" | grep -q '"shortId"' && ok "$u: VM 'same' created" || no "$u VM: $R"
done
for u in $A $B; do
  for _ in $(seq 120); do as $u $W/$u POST /vms/same/exec '{"command":"true"}' | grep -q '"exitCode" : 0' && break; sleep 0.5; done
done
SA=$(as $A $W/$A GET /state); SB=$(as $B $W/$B GET /state)
IDA=$(echo "$SA" | python3 -c "import json,sys; print(','.join(v['id'][:8] for v in json.load(sys.stdin)['vms']))")
IDB=$(echo "$SB" | python3 -c "import json,sys; print(','.join(v['id'][:8] for v in json.load(sys.stdin)['vms']))")
[ -n "$IDA" ] && [ -n "$IDB" ] && [ "$IDA" != "$IDB" ] && [[ "$IDA" != *,* ]] && [[ "$IDB" != *,* ]] \
  && ok "each /state lists exactly its own VM ($IDA vs $IDB)" || no "/state: '$IDA' / '$IDB'"
# Control sockets: the other user (and any other login) can't even connect.
for pair in "$A $B" "$B $A"; do set -- $pair
  sudo -n -u $1 python3 -c "import socket; s=socket.socket(socket.AF_UNIX); s.connect('/run/bromure-ac/sock/$2.sock')" 2>/dev/null \
    && no "$1 connected to $2's socket" || ok "$1 can't connect to $2's control socket"
done
python3 -c "import socket; s=socket.socket(socket.AF_UNIX); s.connect('/run/bromure-ac/sock/$A.sock')" 2>/dev/null \
  && no "$(id -un) connected to $A's socket" || ok "another login ($(id -un)) can't connect to $A's socket"
# Guest network: no route to the host's own addresses (the gateway included); Internet fine.
LAN=$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')
R=$(as $A $W/$A POST /vms/same/exec "{\"command\":\"timeout 4 bash -c 'exec 3<>/dev/tcp/$LAN/$PORT' 2>/dev/null && echo REACHED || echo BLOCKED\",\"timeout\":15}")
echo "$R" | grep -q BLOCKED && ok "$A's guest can't reach the host ($LAN:$PORT)" || no "$A's guest reached the host: $R"
R=$(as $A $W/$A POST /vms/same/exec "{\"command\":\"timeout 6 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' && echo REACHED || echo BLOCKED\",\"timeout\":15}")
echo "$R" | grep -q REACHED && ok "$A's guest still reaches the Internet" || no "$A's guest has no Internet: $R"
# B's guest and A's guest both serve; A's forward to B's address reaches A's own guest.
for u in $A $B; do
  as $u $W/$u POST /vms/same/exec "{\"command\":\"mkdir -p /tmp/w && echo from-$u > /tmp/w/i && cd /tmp/w && (nohup python3 -m http.server 8080 >/dev/null 2>&1 &)\"}" >/dev/null
done
sleep 1
IP=$(echo "$SB" | python3 -c "import json,sys; print(json.load(sys.stdin)['vms'][0]['ip'])")
R=$(req GET /i | timeout 20 ssh "${SSHO[@]}" -i $W/$A -o IdentitiesOnly=yes "$A@$HOST" "bromure-fatclient/1 forward $IP 8080" 2>/dev/null | tail -1)
[ "$R" = from-$A ] && ok "$A's forward to $IP reaches A's own guest, not B's" || no "$A's forward: '$R'"
R=$(req GET /i | timeout 20 ssh "${SSHO[@]}" -i $W/$B -o IdentitiesOnly=yes "$B@$HOST" "bromure-fatclient/1 forward $IP 8080" 2>/dev/null | tail -1)
[ "$R" = from-$B ] && ok "$B's forward reaches B's guest" || no "$B's forward: '$R'"
# A crash of A's daemon: A's VM re-adopted, B untouched.
PB=$(systemctl show bromure-ac@$B -p MainPID --value); PA=$(systemctl show bromure-ac@$A -p MainPID --value)
sudo -n kill -9 $PA; sleep 5
[ "$(systemctl show bromure-ac@$B -p MainPID --value)" = "$PB" ] && as $A $W/$A POST /vms/same/exec '{"command":"true"}' | grep -q '"exitCode" : 0' \
  && ok "$A's daemon crash: $A's VM re-adopted, $B untouched" || no "crash isolation"
echo "MULTIUSER: $pass passed, $fail failed"
[ $fail = 0 ]
