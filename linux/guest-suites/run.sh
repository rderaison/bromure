#!/bin/bash
# run.sh [--keep] [suite...]
# Runs the OpenShell guest suites (scripts/openshell-guest/tests) in a bromure-ac daemon VM on
# the baked amd64 image: test_sentry -> test_boot (all configs) -> test_sandbox -> test_net_flow
# -> test_strict -> test_lockdown --raise (last: raising lockdown is one-way for the boot).
#
# The VM is a throwaway: a private daemon (its own XDG dirs), one q35 VM with the ext4 home disk.
# The suites expect the repo layout plus the drop's `patched/` copies, so both are staged into the
# VM's meta share and copied to /opt/repo; the guest gets the kernel headers (test_sentry builds
# the module), dig and nc (test_net_flow's lineage checks).
#
# Exit status: 0 when every FAIL is in expected-failures.tsv with its expected count; 1 on any
# unexpected FAIL (or a suite that died without one); 2 when an expected failure now passes
# (update expected-failures.tsv). Logs: $OUT (default /tmp/acl-gs-out.XXXXXX), kept.
# Needs: linux/ACLinux built (`swift build -c release --product bromure-ac`), the baked image,
# KVM + vhost (or passwordless `sudo -g kvm`), and the host's vsock port 5800 free (one VM job at a time).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
if [ ! -w /dev/vhost-vsock ] && sudo -n -g kvm true 2>/dev/null && [ -z "${ACL_GS_ELEVATED:-}" ]; then
  exec sudo -n -g kvm env PATH="$PATH" HOME="$HOME" ACL_GS_ELEVATED=1 OUT="${OUT:-}" "$0" "$@"
fi
KEEP=0; [ "${1:-}" = --keep ] && { KEEP=1; shift; }
SUITES=("$@"); [ ${#SUITES[@]} -gt 0 ] || SUITES=(test_sentry test_boot test_sandbox test_net_flow test_strict test_lockdown)
BIN=$ROOT/linux/ACLinux/.build/release/bromure-ac
[ -x "$BIN" ] || { echo "build it first: swift build --package-path linux/ACLinux -c release --product bromure-ac"; exit 1; }
OUT=${OUT:-$(mktemp -d /tmp/acl-gs-out.XXXXXX)}; mkdir -p "$OUT"
W=$(mktemp -d /tmp/acl-gs.XXXXXX)          # short: it holds the daemon's sockets
export XDG_RUNTIME_DIR=$W/run XDG_STATE_HOME=$W/state
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
T0=$(date +%s)
log() { echo "[guest-suites $(date +%T)] $*"; }
cli() { "$BIN" "$@"; }

BROMURE_AGENTD="$ROOT/Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py" "$BIN" daemon > "$OUT/daemon.log" 2>&1 &
DAEMON=$!
cleanup() {
  cli vm kill --force gs >/dev/null 2>&1
  kill -TERM $DAEMON 2>/dev/null; wait $DAEMON 2>/dev/null
  [ $KEEP = 1 ] || rm -rf "$W"
}
trap cleanup EXIT
for _ in $(seq 100); do [ -S "$XDG_RUNTIME_DIR/bromure-ac/control.sock" ] && break; sleep 0.1; done
ID=$(cli vm run --name gs --machine q35 --cpus 8 --memory-gb 8) || { log "vm run failed"; cat "$OUT/daemon.log"; exit 1; }
log "VM $ID up"

# Stage: the repo layout, and the drop layout the suites' ROOT expects (vm-setup + tests + sentry
# + patched/{agentd,attestd}).
M=$XDG_STATE_HOME/bromure-ac/vms/$ID/meta/repo
VS=$ROOT/Sources/AgentCoding/Resources/vm-setup; OG=$M/scripts/openshell-guest
mkdir -p "$M/Sources/AgentCoding/Resources" "$OG/patched"
cp -a "$VS" "$M/Sources/AgentCoding/Resources/"
cp -a "$VS/." "$OG/"
cp -a "$ROOT/scripts/openshell-guest/tests" "$ROOT/scripts/openshell-guest/sentry" "$OG/"
cp "$VS/bromure-agentd.py" "$VS/bromure-attestd.py" "$OG/patched/"
cli vm exec --timeout 900 gs -- bash -c '
  set -e
  for _ in $(seq 60); do findmnt -no FSTYPE /home/ubuntu | grep -q ext4 && break; sleep 1; done
  sudo cp -a /mnt/bromure-meta/repo /opt/repo && sudo chown -R ubuntu:ubuntu /opt/repo
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "linux-headers-$(uname -r)" dnsutils netcat-openbsd >/dev/null
  echo guest-ready' > "$OUT/setup.log" 2>&1
grep -q guest-ready "$OUT/setup.log" || { log "guest setup failed:"; tail -20 "$OUT/setup.log"; exit 1; }
log "guest ready ($(( $(date +%s) - T0 ))s)"

declare -A RC SECS
for s in "${SUITES[@]}"; do
  args=""; [ "$s" = test_lockdown ] && args="--raise"
  t=$(date +%s)
  cli vm exec --timeout 1800 gs -- bash -c "cd /opt/repo/scripts/openshell-guest && bash tests/$s.sh $args 2>&1; echo \"SUITE_RC=\$?\"" > "$OUT/$s.log" 2>&1
  RC[$s]=$(sed -n 's/^SUITE_RC=//p' "$OUT/$s.log" | tail -1); RC[$s]=${RC[$s]:-none}
  SECS[$s]=$(( $(date +%s) - t ))
  log "$s: rc ${RC[$s]} in ${SECS[$s]}s"
done

# The verdict.
python3 - "$OUT" "$HERE/expected-failures.tsv" "${SUITES[@]}" <<'PY'
import os, re, sys
out, tsv, suites = sys.argv[1], sys.argv[2], sys.argv[3:]
expected = []
for line in open(tsv):
    if line.startswith("#") or not line.strip():
        continue
    suite, rx, count, why = line.rstrip("\n").split("\t")
    expected.append((suite, re.compile(rx), int(count), why))
status, unexpected_pass = 0, 0
print("\n%-15s %4s %6s %6s %10s %6s" % ("suite", "rc", "ok", "FAIL", "unexpected", "SKIP"))
for s in suites:
    lines = open(os.path.join(out, s + ".log"), errors="replace").read().splitlines()
    rc = next((l.split("=", 1)[1] for l in reversed(lines) if l.startswith("SUITE_RC=")), "none")
    ok = sum(1 for l in lines if re.match(r"\s*ok\s", l))
    fails = [l.strip() for l in lines if re.match(r"\s*FAIL\s", l)]
    skips = sum(1 for l in lines if re.match(r"\s*SKIP\s", l))
    mine = [e for e in expected if e[0] == s]
    unexpected = [f for f in fails if not any(e[1].search(f) for e in mine)]
    print("%-15s %4s %6d %6d %10d %6d" % (s, rc, ok, len(fails), len(unexpected), skips))
    for f in unexpected:
        print("    UNEXPECTED " + f[:160])
    if unexpected or (rc not in ("0", "1", "77") ) or (rc == "1" and not fails):
        status = max(status, 1)
        if rc == "1" and not fails:
            print("    the suite exited 1 without a FAIL line")
        if rc not in ("0", "1", "77"):
            print("    the suite did not finish normally (rc %s)" % rc)
print("\nexpected failures:")
for suite, rx, count, why in expected:
    if suite not in suites:
        continue
    lines = open(os.path.join(out, suite + ".log"), errors="replace").read().splitlines()
    seen = sum(1 for l in lines if rx.search(l.strip()) or rx.search(l))
    if seen == count:
        verdict = "expected (%d)" % seen
    elif seen < count:
        verdict = "UNEXPECTED PASS: %d of %d still fail -- update expected-failures.tsv" % (seen, count)
        unexpected_pass = 1
    else:
        verdict = "seen %d times, expected %d" % (seen, count)
        status = max(status, 1)
    print("  %-14s %-58s %s" % (suite, rx.pattern[:58], verdict))
    print("  %-14s %s" % ("", why[:110]))
sys.exit(status if status else (2 if unexpected_pass else 0))
PY
V=$?
log "total $(( $(date +%s) - T0 ))s; logs in $OUT; exit $V"
exit $V
