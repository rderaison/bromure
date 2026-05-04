#!/usr/bin/env bash
# Bromure AC — WSL Ubuntu dev-tooling setup.
#
# Run inside the Ubuntu WSL shell once setup-dev-toolchain.ps1 has finished.
# Installs the Linux-side tooling we need for building the guest qcow2 image
# and cross-compiling the guest Rust agents (fb-agent, clip-agent).

set -euo pipefail

echo ">>> Installing apt packages"
sudo apt update
sudo apt install -y \
    build-essential \
    cloud-image-utils \
    genisoimage \
    qemu-utils \
    python3-pip \
    python3-venv \
    pkg-config \
    libssl-dev \
    musl-tools

if ! command -v cargo >/dev/null 2>&1; then
    echo ">>> Installing Rust toolchain"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env"
fi

rustup target add x86_64-unknown-linux-musl

echo
echo "=== Versions ==="
cargo --version
qemu-img --version | head -1
cloud-localds --help 2>&1 | head -1
