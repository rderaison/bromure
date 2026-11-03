"""OpenShell e2e/rust batch A, replayed against Bromure.

Every fixture, policy and workload script is OpenShell's own, verbatim, from
fixtures/ (extracted from e2e/rust/tests/*.rs). The only changes are the ones
the harness itself makes: the fixture's address (__HOST__/__PORT__), and
OpenShell's /sandbox workdir mapped to the Bromure workspace home.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import socket
import struct
import subprocess
import sys
import time

from bromure_e2e import (BASE_SANDBOX, HOST_IP, HOST_NAME, PLACEHOLDER_PREFIX, WORKDIR, CredentialWorkspace,
                         NotApplicable, TcpServer, Workspace, case, check, manual_token)

FIX = os.path.join(os.path.dirname(__file__), "fixtures")
WS = Workspace("E2E OpenShell")


def fx(name: str) -> str:
    with open(os.path.join(FIX, name)) as f:
        return f.read()


def free_port() -> int:
    s = socket.socket()
    s.bind(("0.0.0.0", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class Fixture:
    """OpenShell's ContainerHttpServer, as a host process: the same script,
    listening on a free port instead of 8000 in a container."""

    def __init__(self, script: str):
        self.port = free_port()
        script = script.replace('("0.0.0.0", 8000)', f'("0.0.0.0", {self.port})')
        self.proc = subprocess.Popen([sys.executable, "-c", script],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        deadline = time.time() + 20
        while time.time() < deadline:
            try:
                socket.create_connection(("127.0.0.1", self.port), timeout=1).close()
                return
            except OSError:
                time.sleep(0.2)
        raise RuntimeError(f"fixture never listened: {self.proc.stderr.read1(4000)!r}")

    def close(self) -> None:
        self.proc.kill()


def localize(text: str, port: int | None = None) -> str:
    text = text.replace("/sandbox", WORKDIR).replace("__HOST__", HOST_NAME)
    if port is not None:
        text = text.replace("__PORT__", str(port))
    return text


def run_workload(policy: str, argv: list[str], timeout: int = 180) -> str:
    """SandboxGuard::create: the policy applied, the workload run, and its exit
    status required to be 0. Returns stdout+stderr (their `create_output`)."""
    WS.ensure(policy)
    r = WS.exec(argv, timeout=timeout)
    output = r.out + r.err
    check(r.rc == 0, f"workload exited {r.rc}: {output.strip()[-1500:]}")
    return output


def expect_keys(output: str, expected: dict[str, int]) -> None:
    missing = [f'"{k}": {v}' for k, v in expected.items() if f'"{k}": {v}' not in output]
    check(not missing, f"missing {missing}; output: {output.strip()[-1500:]}")


# OpenShell's default policy (no --policy): filesystem + landlock, no network.
DEFAULT_POLICY = "version: 1\n" + BASE_SANDBOX + "network_policies: {}\n"


@case("landlock::hard_requirement_accepts_enriched_device_path", "e2e/rust/tests/landlock.rs")
def landlock_hard_requirement():
    out = run_workload(localize(fx("landlock_policy.yaml")), ["sh", "-lc",
        'set -eu; bytes=$(head -c 16 /dev/urandom | wc -c); test "$bytes" -eq 16; printf landlock-ok > '
        '/tmp/landlock-check; test "$(cat /tmp/landlock-check)" = landlock-ok; echo landlock-hard-requirement-ok'])
    check("landlock-hard-requirement-ok" in out, out)


@case("bypass_detection::bypass_attempt_is_rejected_fast", "e2e/rust/tests/bypass_detection.rs")
def bypass_detection():
    out = run_workload(DEFAULT_POLICY, ["python3", "-c", fx("bypass_detection_0_L23.txt")])
    line = next((l for l in out.splitlines() if "bypass_result" in l), None)
    check(line is not None, f"no bypass_result line: {out}")
    doc = json.loads(line)
    check(doc["bypass_result"] == "denied", f"bypass_result={doc['bypass_result']} (expected denied)")
    check(doc["elapsed_ms"] < 8000, f"elapsed_ms={doc['elapsed_ms']}")


@case("core_dump_hardening::sandbox_processes_disable_core_dumps", "e2e/rust/tests/core_dump_hardening.rs")
def core_dump():
    out = run_workload(DEFAULT_POLICY, ["sh", "-lc", 'test "$(ulimit -c)" = 0 && echo core-limit-ok'])
    check("core-limit-ok" in out, out)


@case("no_proxy::sandbox_reaches_localhost_without_proxy_environment", "e2e/rust/tests/no_proxy.rs")
def no_proxy():
    out = run_workload(DEFAULT_POLICY, ["python3", "-c", fx("no_proxy_0_L9.txt")])
    check('{"proxy_env_absent": true, "payload": {"message": "hello"}}' in out, out)


@case("user_namespaces::sandbox_pod_spec_has_user_namespace_fields", "e2e/rust/tests/user_namespaces.rs")
def user_namespaces():
    raise NotApplicable("Kubernetes pod-spec test (and #[ignore] upstream)")


GRAPHQL_EXPECT = {
    "forward_query_allowed": 200, "forward_get_query_allowed": 200, "forward_duplicate_get_denied": 403,
    "forward_persisted_get_allowed": 200, "forward_unregistered_persisted_get_denied": 403,
    "forward_chunked_query_allowed": 200, "forward_unlisted_field_denied": 403, "forward_mutation_allowed": 200,
    "forward_deny_rule_denied": 403, "raw_query_allowed": 200, "raw_get_query_allowed": 200,
    "raw_duplicate_get_denied": 403, "raw_persisted_get_allowed": 200, "raw_unregistered_persisted_get_denied": 403,
    "raw_chunked_query_allowed": 200, "raw_unlisted_field_denied": 403, "raw_mutation_allowed": 200,
    "raw_deny_rule_denied": 403,
}


def l7(fixture: str, policy: str, workload: str, expected: dict[str, int]) -> None:
    fixture_proc = Fixture(fx(fixture))
    try:
        out = run_workload(localize(fx(policy), fixture_proc.port),
                           ["python3", "-c", localize(fx(workload), fixture_proc.port)])
        expect_keys(out, expected)
    finally:
        fixture_proc.close()


@case("forward_proxy_graphql_l7::graphql_l7_enforces_high_level_and_raw_transparent_paths",
      "e2e/rust/tests/forward_proxy_graphql_l7.rs")
def graphql_l7():
    l7("forward_proxy_graphql_l7_0_L22.txt", "forward_proxy_graphql_l7_1_L64_fmt.txt",
       "forward_proxy_graphql_l7_2_L142_fmt.txt", GRAPHQL_EXPECT)


@case("forward_proxy_jsonrpc_l7::jsonrpc_l7_enforces_high_level_and_raw_transparent_paths",
      "e2e/rust/tests/forward_proxy_jsonrpc_l7.rs")
def jsonrpc_l7():
    l7("forward_proxy_jsonrpc_l7_0_L23.txt", "forward_proxy_jsonrpc_l7_1_L65_fmt.txt",
       "forward_proxy_jsonrpc_l7_3_L201_fmt.txt", {
           "forward_method_initialize_allowed": 200, "forward_method_tools_list_allowed": 200,
           "forward_method_tools_call_allowed": 200, "forward_method_tools_call_with_unmatched_params_allowed": 200,
           "forward_method_tools_delete_denied": 403, "forward_batch_all_allowed": 200,
           "forward_batch_one_denied": 403, "forward_invalid_json_denied": 403,
           "raw_method_initialize_allowed": 200, "raw_method_tools_list_allowed": 200,
           "raw_method_tools_call_allowed": 200, "raw_method_tools_call_with_unmatched_params_allowed": 200,
           "raw_method_tools_delete_denied": 403})


@case("forward_proxy_jsonrpc_l7::jsonrpc_forward_proxy_hard_denies_response_frames_in_default_audit_mode",
      "e2e/rust/tests/forward_proxy_jsonrpc_l7.rs")
def jsonrpc_audit():
    l7("forward_proxy_jsonrpc_l7_0_L23.txt", "forward_proxy_jsonrpc_l7_2_L130_fmt.txt",
       "forward_proxy_jsonrpc_l7_5_L448_fmt.txt",
       {"forward_unknown_method_audited": 200, "forward_response_frame_hard_denied": 403})


@case("forward_proxy_l7_bypass::forward_proxy_allows_l7_permitted_request", "e2e/rust/tests/forward_proxy_l7_bypass.rs")
def rest_allowed():
    fixture_proc = Fixture(fx("forward_proxy_l7_bypass_0_L18.txt"))
    try:
        out = run_workload(localize(fx("forward_proxy_l7_bypass_1_L40_fmt.txt"), fixture_proc.port),
                           ["python3", "-c", localize(fx("forward_proxy_l7_bypass_2_L110_fmt.txt"), fixture_proc.port)])
        check('"status": 200' in out, out)
    finally:
        fixture_proc.close()


@case("forward_proxy_l7_bypass::forward_proxy_denies_l7_blocked_request", "e2e/rust/tests/forward_proxy_l7_bypass.rs")
def rest_denied():
    fixture_proc = Fixture(fx("forward_proxy_l7_bypass_0_L18.txt"))
    try:
        out = run_workload(localize(fx("forward_proxy_l7_bypass_1_L40_fmt.txt"), fixture_proc.port),
                           ["python3", "-c", localize(fx("forward_proxy_l7_bypass_3_L162_fmt.txt"), fixture_proc.port)])
        check('"status": 403' in out, out)
    finally:
        fixture_proc.close()


def mcp(policy_file: str, versions: list[str], client_fragment: str) -> str:
    compact = json.dumps(versions, separators=(",", ":"))
    fixture_proc = Fixture(f"SUPPORTED_VERSIONS = {compact}\n" + fx("mcp_sessionless_0_L20.txt"))
    try:
        script = (f'HOST = "{HOST_NAME}"\nPORT = {fixture_proc.port}\nSELECTED_VERSIONS = {compact}\n'
                  + fx("mcp_sessionless_1_L139.txt") + "\n" + fx(client_fragment))
        return run_workload(localize(fx(policy_file), fixture_proc.port), ["python3", "-c", script])
    finally:
        fixture_proc.close()


@case("mcp_sessionless::sessionless_discovery_tools_and_subscription_use_request_metadata",
      "e2e/rust/tests/mcp_sessionless.rs")
def mcp_sessionless():
    out = mcp("mcp_policy_sessionless.yaml", ["2026-07-28"], "mcp_sessionless_2_L179.txt")
    check("MCP_SESSIONLESS_OK discovery=200 allowed_tool=200 denied_tool=403 subscription=200" in out, out)


@case("mcp_sessionless::legacy_and_multi_version_profiles_authorize_tools_through_sandbox",
      "e2e/rust/tests/mcp_sessionless.rs")
def mcp_profiles():
    for policy_file, versions in (("mcp_policy_v20250326.yaml", ["2025-03-26"]),
                                  ("mcp_policy_v20250618.yaml", ["2025-06-18"]),
                                  ("mcp_policy_multi.yaml", ["2025-11-25", "2026-07-28"])):
        out = mcp(policy_file, versions, "mcp_sessionless_3_L212.txt")
        for v in versions:
            want = f"MCP_PROFILE_OK version={v} allowed_tool=200 denied_tool=403 receipts=verified"
            check(want in out, f"{v}: {out.strip()[-1200:]}")


WS_SECRET = "sk-e2e-websocket-conformance-secret"
WS_CREDS = CredentialWorkspace("E2E OpenShell Creds WebSocket")


def _cover_host_ip(policy: str) -> str:
    """allowed_ips must cover the Mac, whatever private range it sits in."""
    return re.sub(r'^(\s*)- "10\.0\.0\.0/8"$', lambda m: f'{m.group(0)}\n{m.group(1)}- "{HOST_IP}/32"',
                  policy, flags=re.M)


def _ws_frame_reply(text: str) -> bytes:
    data = text.encode()
    if len(data) < 126:
        header = bytes([0x81, len(data)])
    elif len(data) <= 0xFFFF:
        header = bytes([0x81, 126]) + struct.pack("!H", len(data))
    else:
        header = bytes([0x81, 127]) + struct.pack("!Q", len(data))
    return header + data


def websocket_probe(conn: socket.socket, server: TcpServer) -> None:
    """The upstream probe of websocket_conformance.rs: 101 on an upgrade, then
    one client frame answered with saw_placeholder / saw_secret (never an
    echo of the payload)."""
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            return
        data += chunk
    head, _, rest = data.partition(b"\r\n\r\n")
    if b"upgrade: websocket" not in head.lower():
        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
        return
    key = None
    for line in head.split(b"\r\n")[1:]:
        k, _, v = line.partition(b":")
        if k.strip().lower() == b"sec-websocket-key":
            key = v.strip()
    if key is None:
        return
    accept = base64.b64encode(hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
    conn.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                 b"Sec-WebSocket-Accept: " + accept + b"\r\n\r\n")
    buf = rest

    def need(n: int) -> bytes:
        nonlocal buf
        while len(buf) < n:
            chunk = conn.recv(65536)
            if not chunk:
                raise EOFError("websocket frame truncated")
            buf += chunk
        out, buf = buf[:n], buf[n:]
        return out

    _, second = need(2)
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", need(2))[0]
    elif length == 127:
        length = struct.unpack("!Q", need(8))[0]
    mask = need(4) if second & 0x80 else b""
    payload = need(length)
    if mask:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    text = payload.decode("utf-8")
    server.record(payload)
    saw_placeholder = "true" if PLACEHOLDER_PREFIX in text else "false"
    saw_secret = "true" if WS_SECRET in text else "false"
    conn.sendall(_ws_frame_reply(f'{{"saw_placeholder": {saw_placeholder}, "saw_secret": {saw_secret}}}'))


def _ws_policy(port: int, rewrite: bool = True) -> str:
    policy = _cover_host_ip(localize(fx("websocket_conformance_2_L305_fmt.txt"), port))
    if not rewrite:
        flag = "        websocket_credential_rewrite: true\n"
        check(flag in policy, "fixture drifted: websocket_credential_rewrite not found")
        policy = policy.replace(flag, "")
    return policy


@case("websocket_conformance::websocket_text_placeholder_is_rewritten_transparently",
      "e2e/rust/tests/websocket_conformance.rs")
def websocket_placeholder():
    # The OpenShell provider + profile (`profile import`, `provider create
    # --credential WS_E2E_TOKEN=...`, `--provider`) become one Bromure manual
    # token on a dedicated workspace with `openShellCredentialPlaceholders`:
    # env WS_E2E_TOKEN, bound to HOST_NAME, path /ws (the profile endpoint's
    # path). The policy is upstream's, `websocket_credential_rewrite: true`
    # kept. Dropped: provider/profile CRUD and its cleanup (no Bromure
    # equivalent). Added (Bromure-side control, not upstream): with
    # `websocket_credential_rewrite` removed, the placeholder is NOT resolved.
    server = TcpServer(websocket_probe)
    try:
        WS_CREDS.ensure_with_credentials(_ws_policy(server.port), [
            manual_token("websocket_token", WS_SECRET, "WS_E2E_TOKEN", [HOST_NAME], ["/ws"])])
        WS_CREDS.check_placeholder_env("WS_E2E_TOKEN")
        client = localize(fx("websocket_conformance_3_L359_fmt.txt"), server.port)
        r = WS_CREDS.workload(["python3", "-c", client], timeout=120)
        out = r.out + r.err
        check(r.rc == 0, f"workload exited {r.rc}: {out.strip()[-1500:]}")
        check(fx("websocket_conformance_4_L503.txt").strip() in out, out.strip()[-1500:])
        check(WS_SECRET not in out, "the secret appeared in the guest output")
        check(PLACEHOLDER_PREFIX not in out, f"the placeholder appeared in the guest output: {out.strip()[-800:]}")
        frames = list(server.records)
        check(frames and all(f'"Bearer {WS_SECRET}"'.encode() in f for f in frames),
              f"upstream frames without the resolved secret: {frames!r}")
        check(not any(PLACEHOLDER_PREFIX.encode() in f for f in frames), f"placeholder reached upstream: {frames!r}")

        # Control: the same message on an endpoint that doesn't opt in.
        WS_CREDS.set_policy(_ws_policy(server.port, rewrite=False))
        r = WS_CREDS.workload(["python3", "-c", client], timeout=120)
        out = r.out + r.err
        check(r.rc == 0, f"[no websocket_credential_rewrite] workload exited {r.rc}: {out.strip()[-1500:]}")
        check('"transparent": {"saw_placeholder": true, "saw_secret": false}' in out,
              f"[no websocket_credential_rewrite] placeholder resolved without the opt-in: {out.strip()[-1500:]}")
        check(WS_SECRET not in out, "[no websocket_credential_rewrite] the secret appeared in the guest output")
    finally:
        server.close()
        WS_CREDS.stop()
