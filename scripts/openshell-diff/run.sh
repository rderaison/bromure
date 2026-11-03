#!/bin/bash
# Differential test: Bromure's OpenShell policy engine vs OpenShell's own.
#
#   scripts/openshell-diff/run.sh <OpenShell checkout> [work dir]
#
# Env: SEED (default 1), N_POLICIES (default 400), FOCUS (""|mcp|graphql|ip|ws).
# Needs cargo (rustup) for the oracle; the first oracle build takes a few
# minutes. Mismatches land in <work dir>/mismatches.jsonl.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OS="$(cd "${1:?usage: run.sh <OpenShell checkout> [work dir]}" && pwd)"
WORK="${2:-$(mktemp -d)}"
mkdir -p "$WORK"
export PATH="$HOME/.cargo/bin:$PATH"

# 1. Cases: random policies + probes, plus every example policy in the checkout.
python3 "$HERE/gen_cases.py" "$WORK/cases.jsonl" "$OS"

# 2. Oracle: OpenShell's gateway validation, Rego engine and relay-side request
#    handling, as a #[cfg(test)] module inside openshell-supervisor-network.
SRC="$OS/crates/openshell-supervisor-network/src"
cp "$HERE/bromure_oracle.rs" "$SRC/bromure_oracle.rs"
grep -q '^mod bromure_oracle;' "$SRC/lib.rs" || echo 'mod bromure_oracle;' >> "$SRC/lib.rs"
# Test-only child modules: they call private helpers of `proxy` (destination
# validation) and `l7::websocket` (GraphQL-over-WebSocket classification).
cp "$HERE/bromure_dest_oracle.rs" "$SRC/proxy/bromure_dest_oracle.rs"
grep -q 'mod bromure_dest_oracle;' "$SRC/proxy.rs" || printf '\n#[cfg(test)]\npub(crate) mod bromure_dest_oracle;\n' >> "$SRC/proxy.rs"
mkdir -p "$SRC/l7/websocket"
cp "$HERE/bromure_ws_oracle.rs" "$SRC/l7/websocket/bromure_ws_oracle.rs"
grep -q 'mod bromure_ws_oracle;' "$SRC/l7/websocket.rs" || printf '\n#[cfg(test)]\npub(crate) mod bromure_ws_oracle;\n' >> "$SRC/l7/websocket.rs"
(cd "$OS" && BROMURE_ORACLE_IN="$WORK/cases.jsonl" BROMURE_ORACLE_OUT="$WORK/oracle.jsonl" \
    cargo test -q -p openshell-supervisor-network --lib bromure_oracle)

# 3. Bromure side: compares every decision, writes mismatches.jsonl + counts.json.
(cd "$REPO" && OPENSHELL_DIFF_DIR="$WORK" swift test --build-system native --filter OpenShellDifferentialTests) || true
cat "$WORK/counts.json"; echo
echo "$(grep -c . "$WORK/mismatches.jsonl" || true) mismatches ($WORK/mismatches.jsonl)"
