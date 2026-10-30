#!/bin/bash
# linux/ci.sh: the Linux CI gate (run on lnx-ntv from the repo root or anywhere in it).
#   1. build the portmap ledger tool (release) and run its tests
#   2. portmap check --allow-unclaimed
#   3. linux/ACLinux: build, unit tests, and the KVM integration tests (they boot
#      linux/bake's image; they skip themselves without /dev/kvm, vhost-vsock or the image)
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
step "ACLinux: KVM integration"
# Until the vhost udev rule is installed, /dev/vhost-vsock is kvm-group only:
# run as this user with the kvm group added (not as root).
if [ -w /dev/vhost-vsock ] || ! sudo -n -g kvm true 2>/dev/null; then
  swift test --package-path "$ROOT/linux/ACLinux" --filter ACLinuxIntegrationTests
else
  sudo -n -g kvm env PATH="$PATH" HOME="$HOME" swift test --package-path "$ROOT/linux/ACLinux" --filter ACLinuxIntegrationTests
fi
step "ok"
