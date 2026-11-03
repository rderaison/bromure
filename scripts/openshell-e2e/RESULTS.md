# OpenShell e2e replay — results

OpenShell's own end-to-end suites (`e2e/rust/tests`, `e2e/python`, `e2e/policy-advisor`, upstream checkout c0eb3db), replayed against real Bromure workspaces by `run.py` with OpenShell's verbatim fixtures, policies and workload scripts (see `fixtures/`).

**36 pass · 7 fail · 37 not applicable** (OpenShell product machinery with no Bromure counterpart: its gateway gRPC/mTLS, exec admission, providers and credential placeholders, provider profiles, revision store, custom images, Kubernetes/podman).

Run: `BROMURE_AC=<.app>/Contents/MacOS/bromure-ac CFFIXED_USER_HOME=<isolated home> python3 run.py [filter…]` (`E2E_HOST_MODE=ip` addresses fixtures by IP, like OpenShell's docker lane).

| Case | Result | Notes |
|---|---|---|
| `landlock::hard_requirement_accepts_enriched_device_path` | pass |  |
| `bypass_detection::bypass_attempt_is_rejected_fast` | fail | Divergence: Bromure refuses at the host switch (TCP RST → ECONNREFUSED); OpenShell fails connect() in the guest with EPERM. The connect is refused immediately either way. |
| `core_dump_hardening::sandbox_processes_disable_core_dumps` | pass |  |
| `no_proxy::sandbox_reaches_localhost_without_proxy_environment` | pass |  |
| `user_namespaces::sandbox_pod_spec_has_user_namespace_fields` | n/a | Kubernetes pod-spec test (and #[ignore] upstream) |
| `forward_proxy_graphql_l7::graphql_l7_enforces_high_level_and_raw_transparent_paths` | pass |  |
| `forward_proxy_jsonrpc_l7::jsonrpc_l7_enforces_high_level_and_raw_transparent_paths` | pass |  |
| `forward_proxy_jsonrpc_l7::jsonrpc_forward_proxy_hard_denies_response_frames_in_default_audit_mode` | pass |  |
| `forward_proxy_l7_bypass::forward_proxy_allows_l7_permitted_request` | pass |  |
| `forward_proxy_l7_bypass::forward_proxy_denies_l7_blocked_request` | pass |  |
| `mcp_sessionless::sessionless_discovery_tools_and_subscription_use_request_metadata` | pass |  |
| `mcp_sessionless::legacy_and_multi_version_profiles_authorize_tools_through_sandbox` | pass |  |
| `websocket_conformance::websocket_text_placeholder_is_rewritten_transparently` | n/a | OpenShell provider credential placeholders (`openshell:resolve:env:`) — Bromure brokers credentials with its own host-side swap instead |
| `proxy_egress_pipeline::policy_reload_updates_transparent_requests_and_closes_existing_http_stream` | pass |  |
| `proxy_egress_pipeline::ambiguous_policy_update_is_rejected_without_replacing_active_policy` | pass |  |
| `proxy_egress_pipeline::transparent_destination_denials_fail_connect_with_eacces` | pass |  |
| `proxy_egress_pipeline::explicit_allowed_ips_and_implicit_ip_literals_succeed_transparently` | pass |  |
| `proxy_egress_pipeline::tls_skip_connect_relays_opaque_bytes_bidirectionally` | pass |  |
| `proxy_egress_pipeline::middleware_redacts_transparent_request_bodies` | pass |  |
| `proxy_egress_pipeline::fail_closed_middleware_blocks_uninspectable_transparent_payload_before_upstream` | pass |  |
| `proxy_egress_pipeline::fail_open_middleware_bypasses_uninspectable_transparent_tls_skip` | pass |  |
| `proxy_egress_pipeline::transparent_pipeline_never_reaches_upstream_as_first_request_overflow` | fail | Gap: Bromure's proxy answers one request per connection (`Connection: close`); a pipelined second request is never forwarded (the security property holds) but gets no 403 of its own. |
| `proxy_egress_pipeline::chunked_pipeline_is_authorized_separately_before_reaching_upstream` | fail | Gap: same as above (no HTTP pipelining). |
| `proxy_egress_pipeline::http_credentials_are_rewritten_in_transparent_headers_and_bodies` | n/a | OpenShell providers/provider profiles and `openshell:resolve:env:` credential placeholders — Bromure brokers credentials with its own host-side token swap |
| `transparent_tcp::rootless_podman_musl_getaddrinfo_uses_udp_policy_dns` | n/a | podman-only upstream (skipped unless OPENSHELL_E2E_DRIVER=podman); tests OpenShell's synthetic policy DNS (198.18.0.0/15) with a zig-built musl probe and `sandbox upload` |
| `transparent_tcp::local_container_native_tcp_uses_policy_dns_and_fails_closed` | pass |  |
| `live_policy_update::l7_append_target_scope_round_trip` | n/a | `openshell policy update --add-allow/--add-deny` incremental merge and `policy get --full --output json` revisions have no Bromure equivalent |
| `live_policy_update::live_policy_update_round_trip` | n/a | asserts OpenShell's gateway revision store (Version/Hash from `policy get`, `policy list` history); Bromure keeps no policy revisions |
| `live_policy_update::live_policy_update_from_empty_network_policies` | pass |  |
| `live_policy_update::initial_sparse_policy_is_acknowledged_as_loaded` | pass |  |
| `policy_activation::invalid_image_provider_bundle_waits_for_repair_before_launch` | n/a | custom `--from` OCI image with an embedded policy, provider/profile CRUD, docker container labels/RestartCount and `sandbox get` phase/conditions |
| `credential_gating::credentialed_endpoint_gates_work_end_to_end` | n/a | OpenShell providers/profiles, `openshell:resolve:env:` placeholders, credential_binding/allow_uninspected_credentials admission and per-exec env injection — Bromure brokers credentials with its own host-side token swap |
| `host_gateway_alias::sandbox_reaches_host_openshell_internal_via_host_gateway_alias` | pass |  |
| `host_gateway_alias::sandbox_receives_eof_after_closing_http_response` | pass |  |
| `host_gateway_alias::static_provider_credentials_are_bound_to_profile_endpoints` | n/a | OpenShell provider profiles with endpoint-bound `openshell:resolve:env:` placeholders — Bromure brokers credentials with its own host-side token swap |
| `test_sandbox_landlock::test_landlock_blocks_write_to_read_only_path` | pass |  |
| `test_sandbox_landlock::test_landlock_allows_write_to_read_write_path` | pass |  |
| `test_sandbox_landlock::test_landlock_allows_read_on_read_only_path` | pass |  |
| `test_sandbox_landlock::test_landlock_blocks_access_outside_policy` | pass |  |
| `test_sandbox_landlock::test_landlock_blocks_user_owned_path_outside_policy` | pass |  |
| `test_sandbox_policy::test_policy_applies_to_exec_commands` | pass |  |
| `test_sandbox_policy::test_transparent_tcp_policy_denies_unauthorized_connections[no-policy]` | fail | Divergence: port 443 carries hostname rules (Bromure's provider layer), so an address-only connect is handed to the TLS layer, which refuses at the ClientHello instead of at connect(). OpenShell avoids this with synthetic DNS. |
| `test_sandbox_policy::test_transparent_tcp_policy_denies_unauthorized_connections[wrong-port]` | fail | Divergence: port 443 carries hostname rules (Bromure's provider layer), so an address-only connect is handed to the TLS layer, which refuses at the ClientHello instead of at connect(). OpenShell avoids this with synthetic DNS. |
| `test_sandbox_policy::test_transparent_tcp_policy_denies_unauthorized_connections[wrong-binary]` | fail | Divergence: port 443 carries hostname rules (Bromure's provider layer), so an address-only connect is handed to the TLS layer, which refuses at the ClientHello instead of at connect(). OpenShell avoids this with synthetic DNS. |
| `test_sandbox_policy::test_conflicting_destination_metadata_is_rejected` | pass |  |
| `test_policy_validation::test_create_sandbox_rejects_root_user` | pass |  |
| `test_policy_validation::test_create_sandbox_rejects_path_traversal` | pass |  |
| `test_policy_validation::test_create_sandbox_rejects_overly_broad_paths` | pass |  |
| `test_policy_validation::test_create_sandbox_materializes_default_mcp_version` | n/a | Bromure stores the workspace's policy YAML verbatim (GET /profiles/<name>?full=1 returns the authored text) and the effective policy (policy.local /v1/policy/current) is that text plus provider rules; MCP defaults (versions [2025-11-25]) are applied at evaluation (OpenShellPolicy.MCPOptions), never  |
| `test_policy_validation::test_update_policy_rejects_immutable_fields` | n/a | Bromure has no live-update rejection for filesystem/landlock/process: those sections are applied at the next VM start (a saved change restarts the workspace) rather than refused on a running sandbox; only network_policies apply live |
| `test_security_tls::TestServerMtlsEnforcement::test_authenticated_client_succeeds` | n/a | OpenShell gateway gRPC mTLS transport test; Bromure has no gRPC gateway (its control channel is an owner-only Unix socket / SSH), so there is no client-certificate endpoint to exercise |
| `test_security_tls::TestServerMtlsEnforcement::test_no_client_cert_rejected` | n/a | OpenShell gateway gRPC mTLS transport test; Bromure has no gRPC gateway (its control channel is an owner-only Unix socket / SSH), so there is no client-certificate endpoint to exercise |
| `test_security_tls::TestServerMtlsEnforcement::test_wrong_client_cert_rejected` | n/a | OpenShell gateway gRPC mTLS transport test; Bromure has no gRPC gateway (its control channel is an owner-only Unix socket / SSH), so there is no client-certificate endpoint to exercise |
| `test_security_tls::TestServerMtlsEnforcement::test_plaintext_connection_rejected` | n/a | OpenShell gateway gRPC mTLS transport test; Bromure has no gRPC gateway (its control channel is an owner-only Unix socket / SSH), so there is no client-certificate endpoint to exercise |
| `test_exec_admission::test_exec_request_id_never_relaunches_or_replays_output[False]` | n/a | OpenShell gateway ExecSandbox request-id admission/replay semantics (REQUEST_OUTCOME_UNCERTAIN, REQUEST_ID_PAYLOAD_MISMATCH, REQUEST_STREAM_UNAVAILABLE); Bromure's `vm exec` has no request-id admission layer |
| `test_exec_admission::test_exec_request_id_never_relaunches_or_replays_output[True]` | n/a | OpenShell gateway ExecSandbox request-id admission/replay semantics (REQUEST_OUTCOME_UNCERTAIN, REQUEST_ID_PAYLOAD_MISMATCH, REQUEST_STREAM_UNAVAILABLE); Bromure's `vm exec` has no request-id admission layer |
| `test_exec_admission::test_exec_request_timeout_keeps_launch_unresolved[False]` | n/a | OpenShell gateway ExecSandbox request-id admission/replay semantics (REQUEST_OUTCOME_UNCERTAIN, REQUEST_ID_PAYLOAD_MISMATCH, REQUEST_STREAM_UNAVAILABLE); Bromure's `vm exec` has no request-id admission layer |
| `test_exec_admission::test_exec_request_timeout_keeps_launch_unresolved[True]` | n/a | OpenShell gateway ExecSandbox request-id admission/replay semantics (REQUEST_OUTCOME_UNCERTAIN, REQUEST_ID_PAYLOAD_MISMATCH, REQUEST_STREAM_UNAVAILABLE); Bromure's `vm exec` has no request-id admission layer |
| `test_exec_admission::test_exec_client_cancellation_does_not_clear_launch_admission` | n/a | OpenShell gateway ExecSandbox request-id admission/replay semantics (REQUEST_OUTCOME_UNCERTAIN, REQUEST_ID_PAYLOAD_MISMATCH, REQUEST_STREAM_UNAVAILABLE); Bromure's `vm exec` has no request-id admission layer |
| `test_sandbox_providers::test_provider_credentials_available_as_env_vars` | n/a | OpenShell provider credential placeholders (`openshell:resolve:env:KEY` in the sandbox env); Bromure brokers credentials with its own host-side stand-in swap configured per workspace, not providers |
| `test_sandbox_providers::test_profileless_provider_creation_is_rejected` | n/a | OpenShell provider catalog (provider profiles) CRUD; Bromure has no provider objects |
| `test_sandbox_providers::test_endpointless_profile_credentials_fail_closed_without_policy_binding` | n/a | OpenShell provider profiles / credential_binding of provider placeholders; no Bromure equivalent |
| `test_sandbox_providers::test_endpointless_profile_credentials_use_explicit_policy_binding` | n/a | OpenShell provider profiles / credential_binding of provider placeholders; no Bromure equivalent |
| `test_sandbox_providers::test_nvidia_provider_injects_nvidia_api_key_env_var` | n/a | OpenShell provider credential placeholders injected as env vars; no Bromure provider objects |
| `test_sandbox_providers::test_attach_detach_updates_credentials_for_later_exec_launches` | n/a | OpenShell AttachSandboxProvider/DetachSandboxProvider gateway API; no Bromure equivalent |
| `test_sandbox_providers::test_imported_openai_profile_allows_native_endpoint_with_attached_provider` | n/a | OpenShell ImportProviderProfiles + workspace-scoped provider profile + attached provider placeholder swap; no Bromure provider-profile import API |
| `test_sandbox_providers::test_imported_anthropic_profile_allows_native_endpoint_with_attached_provider` | n/a | OpenShell ImportProviderProfiles + workspace-scoped provider profile + attached provider placeholder swap; no Bromure provider-profile import API |
| `test_sandbox_providers::test_create_sandbox_rejects_unknown_provider` | n/a | OpenShell SandboxSpec.providers references; Bromure workspaces don't reference named providers |
| `test_sandbox_providers::test_credentials_not_in_persisted_spec_environment` | n/a | OpenShell GetSandbox persisted spec.environment of provider credentials; no Bromure provider objects |
| `test_sandbox_providers::test_update_provider_preserves_unset_credentials_and_config` | n/a | OpenShell UpdateProvider merge semantics (provider CRUD); no Bromure equivalent |
| `test_sandbox_providers::test_update_provider_empty_maps_preserves_all` | n/a | OpenShell UpdateProvider merge semantics (provider CRUD); no Bromure equivalent |
| `test_sandbox_providers::test_update_provider_merges_config_preserves_credentials` | n/a | OpenShell UpdateProvider merge semantics (provider CRUD); no Bromure equivalent |
| `test_sandbox_providers::test_update_provider_rejects_type_change` | n/a | OpenShell UpdateProvider type immutability (provider CRUD); no Bromure equivalent |
| `test_sandbox_providers::test_provider_profile_platform_vs_workspace_isolation` | n/a | OpenShell provider-profile catalog platform vs workspace scoping; no Bromure equivalent |
| `test_sandbox_providers::test_cross_workspace_profile_ids_do_not_collide` | n/a | OpenShell provider-profile catalog workspace scoping; no Bromure equivalent |
| `test_sandbox_providers::test_github_provider_allows_https_git_clone` | pass | partial: provider aspect dropped: the github provider's git rules are written into the policy explicitly (github_git) instead of composed from an attached provider; no token involved |
| `policy-advisor/test.sh::agent_proposal_approve_hot_reload_github_write` | pass | partial: host approval (`openshell rule approve-all`) replaced by the host adding the proposed rule through a live policy update (Bromure approves in its UI; the control socket has no approve route); the GitHub write is not performed — no provider/token, so the retried PUT is only required to get pa |
| `policy-advisor/existing-endpoint-auto-approve.sh::existing_endpoint_binary_expansion_keeps_l7` | error | Guest regression found by this run (strict-only workspace gate), fix in progress; passes when the workspace isn't restarted into that configuration. |
| `policy-advisor/wait-smoke.sh::proposal_wait_approved[alpha]` | pass | partial: `openshell rule approve --chunk-id` replaced by the workspace's automatic approval (advisor mode auto; the proposal has no risk findings), so the long-poll resolves on an approval that lands during the submit rather than 0.3 s into the wait |
| `policy-advisor/wait-smoke.sh::proposal_wait_rejected[beta]` | n/a | rejecting a proposal with a reason (`openshell rule reject --reason`) is a UI action in Bromure (OpenShellPolicyEditor); the control socket exposes no reject route, and automatic mode only approves |
