#!/bin/bash
# linux/ci.sh: the Linux CI gate (run on lnx-ntv from the repo root or anywhere in it).
#   1. build the portmap ledger tool (release) and run its tests
#   2. portmap check --allow-unclaimed
# More steps (swift build --target ACCore, ACLinux tests, …) land here as those targets appear.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$HOME/.local/share/swiftly/env.sh" ] && . "$HOME/.local/share/swiftly/env.sh"
step() { printf '\n== %s\n' "$*"; }

step "toolchain"; swift --version 2>&1 | head -1
step "portmap: build (release)"; swift build --package-path "$ROOT/tools/portmap" -c release
step "portmap: test";            swift test  --package-path "$ROOT/tools/portmap"
step "portmap: check";           "$ROOT/tools/portmap/.build/release/portmap" check --root "$ROOT" --allow-unclaimed
step "ok"
