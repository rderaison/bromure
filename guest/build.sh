#!/usr/bin/env bash
# guest/build.sh — cross-compile fb-agent + clip-agent for the Linux
# guest. Run inside WSL Ubuntu (or any Linux box). Produces statically-
# linked musl binaries that the build pipeline drops into the qcow2 base
# image at /usr/local/bin/.
#
# Prereqs (already installed by scripts/windows/setup-wsl.sh):
#   - rustup target add x86_64-unknown-linux-musl
#   - apt install musl-tools
set -euo pipefail

cd "$(dirname "$0")"

target="x86_64-unknown-linux-musl"

echo ">>> Building fb-agent + clip-agent for $target"
cargo build --release --target "$target"

out=target/$target/release
echo
echo "=== Outputs ==="
for bin in fb-agent clip-agent; do
    if [ -f "$out/$bin" ]; then
        size=$(stat -c %s "$out/$bin")
        echo "  $out/$bin  ($size bytes)"
    fi
done

echo
echo "Stage these next to setup.sh in Resources/vm-setup/agents/ for"
echo "the qcow2 base-image build."
