#!/bin/bash
# linux/ci.sh: the Linux CI gate (run on lnx-ntv from the repo root or anywhere in it).
#   1. build the portmap ledger tool (release) and run its tests
#   2. portmap check --allow-unclaimed
#   3. linux/ACLinux: build, unit tests, and the KVM integration tests (they boot
#      linux/bake's image; they skip themselves without /dev/kvm, vhost-vsock or the image)
#   4. the network: setup-network.sh (install, re-install, uninstall) and the stream-port <-> tap
#      bridge with a KVM guest, inside throwaway network namespaces (needs passwordless sudo;
#      the host's own namespace is untouched)
# More steps (swift build --target ACCore, …) land here as those targets appear.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$HOME/.local/share/swiftly/env.sh" ] && . "$HOME/.local/share/swiftly/env.sh"
step() { printf '\n== %s\n' "$*"; }

step "toolchain"; swift --version 2>&1 | head -1
step "portmap: build (release)"; swift build --package-path "$ROOT/tools/portmap" -c release
step "portmap: test";            swift test  --package-path "$ROOT/tools/portmap"
step "portmap: check";           "$ROOT/tools/portmap/.build/release/portmap" check --root "$ROOT" --allow-unclaimed
step "ACLinux: build";          swift build --package-path "$ROOT/linux/ACLinux" --build-tests
step "ACLinux: unit tests";     swift test  --package-path "$ROOT/linux/ACLinux" --skip ACLinuxIntegrationTests
# The integration and stall suites run the release build (`swift test -c release`
# builds it, with testing enabled): routing is ~3x faster than debug.
step "spike: TLS interception (linux/spike/mitm)"
swift build --package-path "$ROOT/linux/spike/mitm" -c release
# The KVM integration step drives it from a guest behind passt (needs Internet).
export BROMURE_MITM_PROXY="$ROOT/linux/spike/mitm/.build/release/mitm-proxy"
step "ACLinux: KVM integration"
# Until the vhost udev rule is installed, /dev/vhost-vsock is kvm-group only:
# run as this user with the kvm group added (not as root).
if [ -w /dev/vhost-vsock ] || ! sudo -n -g kvm true 2>/dev/null; then
  swift test -c release --no-parallel --package-path "$ROOT/linux/ACLinux" --filter ACLinuxIntegrationTests
else
  sudo -n -g kvm env PATH="$PATH" HOME="$HOME" BROMURE_MITM_PROXY="$BROMURE_MITM_PROXY" swift test -c release --no-parallel --package-path "$ROOT/linux/ACLinux" --filter ACLinuxIntegrationTests
fi
step "systemd: the daemon as a transient user unit (Type=notify, ExitType=cgroup)"
# The binary exactly as install-user-service.sh builds it (no testing flags).
swift build --package-path "$ROOT/linux/ACLinux" -c release --product bromure-ac
if systemctl --user is-system-running >/dev/null 2>&1 || [ "$(systemctl --user is-system-running 2>/dev/null)" = degraded ]; then
  CI_STATE=$(mktemp -d /tmp/acl-ci-sd.XXXXXX)
  systemd-run --user --unit=bromure-ac-ci -p Type=notify -p NotifyAccess=main -p ExitType=cgroup \
    --setenv=XDG_STATE_HOME="$CI_STATE" --setenv=XDG_RUNTIME_DIR="$CI_STATE/run" \
    "$ROOT/linux/ACLinux/.build/release/bromure-ac" daemon
  [ "$(systemctl --user is-active bromure-ac-ci)" = active ] || { echo "not active after READY"; exit 1; }
  XDG_RUNTIME_DIR="$CI_STATE/run" "$ROOT/linux/ACLinux/.build/release/bromure-ac" vm ls >/dev/null
  # Only this unit's own cgroup: a real installed bromure-ac.service (and its
  # passt) may be running alongside and must not count.
  CG=/sys/fs/cgroup$(systemctl --user show bromure-ac-ci -p ControlGroup --value)
  [ "$(wc -l < "$CG/cgroup.procs")" -ge 2 ] || { echo "expected the daemon and passt in $CG"; exit 1; }
  systemctl --user stop bromure-ac-ci
  if [ -f "$CG/cgroup.procs" ] && [ -s "$CG/cgroup.procs" ]; then
    echo "processes outlived the unit:"; cat "$CG/cgroup.procs"; exit 1
  fi
  rm -rf "$CI_STATE"
  echo "unit: READY, control.sock served, stop emptied its cgroup ($CG)"
else
  echo "skipped: no systemd user manager"
fi
step "guest suites (opt-in: BROMURE_GUEST_SUITES=1, ~4.5 min)"
# test_sentry -> test_boot -> test_sandbox -> test_net_flow -> test_strict ->
# test_lockdown --raise in a daemon VM; expected failures are listed in
# linux/guest-suites/expected-failures.tsv. Needs the release bromure-ac built above.
if [ "${BROMURE_GUEST_SUITES:-0}" = 1 ]; then
  "$ROOT/linux/guest-suites/run.sh"
else
  echo "skipped (BROMURE_GUEST_SUITES=1 to run)"
fi
step "network: netns bridge test"
if sudo -n true 2>/dev/null; then
  sudo -n "$ROOT/linux/test-network.sh"
else
  echo "skipped: needs passwordless sudo for the network namespaces"
fi
step "ok"
