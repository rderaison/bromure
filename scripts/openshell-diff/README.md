# OpenShell differential test

Checks that Bromure's OpenShell policy engine (`Sources/SandboxEngine/OpenShellPolicy*.swift`)
decides exactly like NVIDIA OpenShell's reference engine.

- `gen_cases.py` generates random policies and probes. Each case is a policy plus a
  connection (host, port, binary, ancestors) and an optional HTTP request. It also
  adds connection probes for every example policy in the OpenShell checkout.
  `FOCUS=mcp`, `graphql`, `ip` (DNS answers, `allowed_ips`, IP literals, control-plane ports) or `ws`
  (WebSocket upgrades with client messages) biases the output toward those checks.
- `bromure_oracle.rs` is a test-only module compiled into
  `openshell-supervisor-network`. For each case it runs:
  - gateway validation (`parse_sandbox_policy`, `validate_and_canonicalize_sandbox_policy`,
    `find_endpoint_ambiguities`);
  - `evaluate_network`;
  - the relay's per-request routing (`select_l7_config_for_path` semantics);
  - canonicalization;
  - GraphQL `classify_request` or MCP `enforce_mcp_protocol_version`;
  - `evaluate_l7_request`;
  - with injected DNS answers, `build_validation_plan` and the destination validators
    (`bromure_dest_oracle.rs`, a child of `proxy`);
  - per WebSocket client message, `inspect_websocket_text_message`
    (`bromure_ws_oracle.rs`, a child of `l7::websocket`).
- `Tests/SafariSandboxTests/OpenShellDifferentialTests.swift` replays the same cases
  through Bromure. It is skipped unless `OPENSHELL_DIFF_DIR` is set.
- `recorder.mjs` is a recording reverse proxy (:3100 → :3000). Put it in front of the
  MCP conformance suite's everything-server to capture real, spec-conformant traffic,
  then turn the capture into cases for the same comparison.

```bash
git clone https://github.com/NVIDIA/OpenShell /tmp/OpenShell
scripts/openshell-diff/run.sh /tmp/OpenShell /tmp/os-diff
SEED=7 FOCUS=mcp N_POLICIES=300 scripts/openshell-diff/run.sh /tmp/OpenShell /tmp/os-diff-mcp
```

Last full run: 2026-09-29 against OpenShell `cfcc373`, re-run against `c0eb3db` the same day. It covered 125,666 cases across 11
corpora (seeds 1/2/3/5, MCP ×2, GraphQL ×2, IP, WebSocket, conformance replay) with 0 mismatches.

`mcp-params/` holds the ground-truth setup for `OpenShellMCPParams.swift`: a Rust program that
decodes payloads with tower-mcp-types' own types (`rust-oracle/`), plus the payload generators.

Known upstream behavior that is mirrored on purpose: OpenShell refuses the legacy MCP
session-termination `DELETE` (no body, revision ≤ 2025-11-25) as "invalid JSON".
