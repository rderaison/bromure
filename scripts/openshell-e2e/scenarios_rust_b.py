"""OpenShell e2e/rust batch B, replayed against Bromure.

Files: proxy_egress_pipeline.rs, transparent_tcp.rs, live_policy_update.rs,
policy_activation.rs, credential_gating.rs, host_gateway_alias.rs.

Every policy and workload script is OpenShell's own, verbatim, from
fixtures/b_*. Placeholders are the spec's @@NAME@@ tokens. The harness
changes only what the environment forces:
  - `host.openshell.internal` -> HOST_NAME (a nip.io name for the Mac),
  - /sandbox -> WORKDIR,
  - allowed_ips widened with "<HOST_IP>/32" if the Mac's address is not
    already inside the listed private ranges,
  - OpenShell's host-side Rust servers (KeepAliveHttpServer, EchoServer, ...)
    re-implemented as bromure_e2e.TcpServer handlers with the same bytes,
  - OpenShell's SupportContainer python scripts run as host processes.
Where a test was changed beyond that, the case says so.
"""

from __future__ import annotations

import ipaddress
import json
import re
import socket
import subprocess
import sys
import time

from bromure_e2e import (HOST_IP, HOST_NAME, PLACEHOLDER_PREFIX, WORKDIR, CredentialWorkspace, NotApplicable,
                         TcpServer, case, check, control, manual_token, read_http_request)
from scenarios_rust_a import WS, Fixture, free_port, fx

PE = "e2e/rust/tests/proxy_egress_pipeline.rs"
TT = "e2e/rust/tests/transparent_tcp.rs"
LPU = "e2e/rust/tests/live_policy_update.rs"
PA = "e2e/rust/tests/policy_activation.rs"
CG = "e2e/rust/tests/credential_gating.rs"
HGA = "e2e/rust/tests/host_gateway_alias.rs"

_PRIVATE = [ipaddress.ip_network(n) for n in ("10.0.0.0/8", "172.0.0.0/8", "192.168.0.0/16")]


# ---------------------------------------------------------------- helpers

def cover_host_ip(policy: str) -> str:
    """Every allowed_ips list that carries OpenShell's private ranges must also
    cover the Mac. They already do when HOST_IP is in 10/8, 172/8 or
    192.168/16; otherwise append "<HOST_IP>/32" next to "10.0.0.0/8"."""
    if any(ipaddress.ip_address(HOST_IP) in n for n in _PRIVATE):
        return policy
    policy = re.sub(r'^(\s*)- "10\.0\.0\.0/8"$', lambda m: f'{m.group(0)}\n{m.group(1)}- "{HOST_IP}/32"',
                    policy, flags=re.M)
    return policy.replace('["10.0.0.0/8"', f'["10.0.0.0/8", "{HOST_IP}/32"')


def render(name: str, **subs) -> str:
    """A b_* fixture with the environment mapping and @@KEY@@ substitutions."""
    text = fx(name).replace("host.openshell.internal", HOST_NAME).replace("/sandbox", WORKDIR)
    for key, value in subs.items():
        token = f"@@{key}@@"
        check(token in text, f"fixture {name} has no {token}")
        text = text.replace(token, str(value))
    left = re.findall(r"@@[A-Z0-9_]+@@", text)
    check(not left, f"fixture {name}: unsubstituted {left}")
    return cover_host_ip(text)


def py_str(value: str) -> str:
    """Rust's `{:?}` of a plain string: a double-quoted literal."""
    return json.dumps(value)


def tail(text: str, n: int = 1500) -> str:
    return text.strip()[-n:]


def pe_policy(port: int, endpoint_options: str = "", middlewares: str = "") -> str:
    """write_policy / write_middleware_policy (PE-BASE)."""
    return render("b_proxy_egress_pipeline_policy.yaml", HOST=HOST_NAME, PORT=port,
                  ENDPOINT_OPTIONS=endpoint_options, MIDDLEWARES=middlewares)


def middleware_policy(port: int, endpoint_options: str, on_error: str) -> str:
    block = render("b_proxy_egress_pipeline_middlewares.yaml", ON_ERROR=on_error, HOST=HOST_NAME)
    return pe_policy(port, endpoint_options, block)


def options(name: str) -> str:
    return fx(name).rstrip("\n")


def status_script(host: str, port: int) -> str:
    return render("b_proxy_egress_pipeline_status.py", HOST_PY=py_str(host), PORT=port)


def parse_json_line(output: str) -> dict:
    """The last line of the output that parses as JSON."""
    for line in reversed(output.splitlines()):
        try:
            doc = json.loads(line)
        except ValueError:
            continue
        if isinstance(doc, dict):
            return doc
    raise AssertionError(f"no JSON line in output: {tail(output)}")


def guest(argv: list[str], timeout: int = 120) -> str:
    """guard.exec: stdout+stderr, failing on a non-zero exit."""
    r = WS.exec(argv, timeout=timeout)
    output = r.out + r.err
    check(r.rc == 0, f"{argv[:2]} exited {r.rc}: {tail(output)}")
    return output


def create(policy: str, argv: list[str], timeout: int = 180) -> str:
    """SandboxGuard::create: policy applied, workload run, exit 0 required."""
    WS.ensure(policy)
    return guest(argv, timeout)


def wait_for_sandbox_file(path: str, log_path: str) -> str:
    return guest(["python3", "-c", render("b_proxy_egress_pipeline_waitfile.py", PATH_PY=py_str(path),
                                          LOG_PY=py_str(log_path), PATH=path)], timeout=90)


def status_is(value, code: int) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value == code


class HostPython:
    """A python fixture as a host process (OpenShell's HostPythonFixture /
    SupportContainer), ready once `wait_port` accepts."""

    def __init__(self, script: str, wait_port: int):
        self.proc = subprocess.Popen([sys.executable, "-c", script], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        deadline = time.time() + 20
        while time.time() < deadline:
            try:
                socket.create_connection(("127.0.0.1", wait_port), timeout=1).close()
                return
            except OSError:
                if self.proc.poll() is not None:
                    break
                time.sleep(0.2)
        self.proc.kill()
        raise RuntimeError(f"host fixture never listened on {wait_port}: {self.proc.stderr.read()[:4000]!r}")

    def close(self) -> None:
        self.proc.kill()


# ---------------------------------------------------------------- host-side servers (proxy_egress_pipeline.rs)

def keep_alive_http(conn: socket.socket, server: TcpServer) -> None:
    """KeepAliveHttpServer."""
    while True:
        req = read_http_request(conn)
        if req is None:
            return
        head = req.split(b"\r\n\r\n", 1)[0]
        close = any(line.strip().lower() == b"connection: close" for line in head.split(b"\r\n"))
        if close:
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
            return
        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok")


def request_body_echo(conn: socket.socket, server: TcpServer) -> None:
    """RequestBodyEchoServer."""
    req = read_http_request(conn)
    if req is None:
        return
    body = req.split(b"\r\n\r\n", 1)[1]
    server.record(body)
    conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                 + str(len(body)).encode() + b"\r\nConnection: close\r\n\r\n" + body)


def pipeline_probe(conn: socket.socket, server: TcpServer) -> None:
    """PipelineProbeServer: everything until 200 ms idle, then one 200."""
    conn.settimeout(0.2)
    data = b""
    while True:
        try:
            chunk = conn.recv(65536)
        except socket.timeout:
            break
        if not chunk:
            break
        data += chunk
    server.record(data)
    conn.settimeout(10)
    conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")


def echo(conn: socket.socket, server: TcpServer) -> None:
    """EchoServer."""
    while True:
        chunk = conn.recv(65536)
        if not chunk:
            return
        server.record(chunk)
        conn.sendall(chunk)


def observed(server: TcpServer) -> bytes:
    with server.lock:
        return b"".join(server.records)


# ---------------------------------------------------------------- proxy_egress_pipeline.rs

@case("proxy_egress_pipeline::policy_reload_updates_transparent_requests_and_closes_existing_http_stream", PE)
def policy_reload_closes_existing_stream():
    server = TcpServer(keep_alive_http)
    try:
        allow = pe_policy(server.port)
        WS.ensure(allow)
        WS.set_policy(allow)  # `policy set --wait` of the same policy: idempotent
        WS.sh("rm -f /tmp/proxy-reload-ready /tmp/proxy-reload-go /tmp/proxy-reload-result "
              "/tmp/proxy-reload-client.log")
        persistent = render("b_proxy_egress_pipeline_persistent.py", HOST_PY=py_str(HOST_NAME), PORT=server.port)
        guest(["sh", "-c", 'nohup python3 -c "$1" >/tmp/proxy-reload-client.log 2>&1 &',
               "proxy-reload-client", persistent])
        wait_for_sandbox_file("/tmp/proxy-reload-ready", "/tmp/proxy-reload-client.log")
        before = parse_json_line(guest(["python3", "-c", status_script(HOST_NAME, server.port)]))

        WS.set_policy(render("b_proxy_egress_pipeline_deny.yaml"))
        guest(["sh", "-c", "touch /tmp/proxy-reload-go"])
        stale_raw = wait_for_sandbox_file("/tmp/proxy-reload-result", "/tmp/proxy-reload-client.log")
        stale = parse_json_line(stale_raw)
        after = parse_json_line(guest(["python3", "-c", status_script(HOST_NAME, server.port)]))

        check(status_is(before.get("first"), 200) and status_is(before.get("second"), 200),
              f"before reload: {before}")
        check(stale.get("failed_closed") is True,
              f"existing keep-alive stream still forwarded after deny-all reload: {stale}")
        check(not status_is(after.get("first"), 200) and not status_is(after.get("second"), 200),
              f"new requests still allowed after deny-all reload: {after}")
    finally:
        server.close()


@case("proxy_egress_pipeline::ambiguous_policy_update_is_rejected_without_replacing_active_policy", PE)
def ambiguous_policy_rejected():
    # Partial: OpenShell compares `policy list` revision history before/after.
    # Bromure has no revision list; the equivalent is that the stored profile
    # policy is byte-identical after the rejected save.
    server = TcpServer(keep_alive_http)
    try:
        valid = pe_policy(server.port)
        WS.ensure(valid)
        WS.set_policy(valid)
        before = parse_json_line(guest(["python3", "-c", status_script(HOST_NAME, server.port)]))
        stored_before = _stored_policy()
        connections_before = server.connections

        error = ""
        try:
            WS.set_policy(render("b_ambiguous_policy_update_ambiguous.yaml", PORT=server.port))
        except RuntimeError as e:
            error = str(e)
        stored_after = _stored_policy()
        after = parse_json_line(guest(["python3", "-c", status_script(HOST_NAME, server.port)]))

        check(status_is(before.get("first"), 200) and status_is(before.get("second"), 200), f"before: {before}")
        check(error.startswith("policy rejected"), "ambiguous policy (terminate + tls: skip on the same "
                                                   "host:port) was accepted")
        # OpenShell: "network endpoint ambiguity validation failed". Bromure's
        # wording may differ; require that the rejection names the ambiguity.
        check("ambigu" in error.lower(), f"rejection does not mention the ambiguity: {error}")
        check(stored_after == stored_before, "the rejected update replaced the active policy")
        check(WS.policy == valid, "harness lost track of the active policy")
        check(status_is(after.get("first"), 200) and status_is(after.get("second"), 200),
              f"traffic stopped after the rejected update: {after}")
        check(server.connections > connections_before,
              f"requests after the rejection never reached the upstream ({server.connections} connections)")
    finally:
        server.close()


def _stored_policy() -> str:
    doc = control("GET", f"/profiles/{WS._quoted()}?full=1")
    return doc.get("profile", doc).get("networkPolicy", "")


# Documented divergence: OpenShell fails connect() in-guest via seccomp-notify
# with EACCES (13). Bromure enforces at the host switch and refuses with a TCP
# RST, so the guest sees ECONNREFUSED (111). Either (or EPERM) passes, as long
# as the refusal is fast (a timeout would mean the packet went out).
DENIED_ERRNOS = {13: "EACCES", 1: "EPERM", 111: "ECONNREFUSED"}

_TIMING_PREFIX = '''
import json as _j, socket as _s, time as _t
_orig_create_connection = _s.create_connection
_ELAPSED = {}
def _timed_create_connection(address, *args, **kwargs):
    started = _t.monotonic()
    try:
        return _orig_create_connection(address, *args, **kwargs)
    finally:
        _ELAPSED["%s:%s" % address[:2]] = round(_t.monotonic() - started, 3)
_s.create_connection = _timed_create_connection
'''
_TIMING_SUFFIX = '\nprint(_j.dumps({"elapsed": _ELAPSED}, sort_keys=True))\n'


@case("proxy_egress_pipeline::transparent_destination_denials_fail_connect_with_eacces", PE)
def destination_denials():
    script = _TIMING_PREFIX + render("b_transparent_destination_denials_client.py") + _TIMING_SUFFIX
    out = create(render("b_transparent_destination_denials_policy.yaml"), ["python3", "-c", script])
    lines = []
    for line in out.splitlines():
        try:
            doc = json.loads(line)
        except ValueError:
            continue
        if isinstance(doc, dict):
            lines.append(doc)
    result = next((d for d in lines if "metadata" in d), None)
    elapsed = next((d["elapsed"] for d in lines if "elapsed" in d), {})
    check(result is not None, f"no result line: {tail(out)}")
    targets = {"metadata": "169.254.169.254:80", "control_plane": "203.0.113.10:6443",
               "outside_allowed_ips": "203.0.113.10:8080"}
    seen = {k: DENIED_ERRNOS.get(result.get(k), result.get(k)) for k in targets}
    for name, addr in targets.items():
        check(result.get(name) in DENIED_ERRNOS,
              f"{name} ({addr}): errno {result.get(name)!r}, expected EACCES/EPERM/ECONNREFUSED; all: {seen}")
        check(elapsed.get(addr, 99) < 5, f"{name} ({addr}) denial took {elapsed.get(addr)}s; all: {elapsed}")


@case("proxy_egress_pipeline::explicit_allowed_ips_and_implicit_ip_literals_succeed_transparently", PE)
def ip_literals():
    # Upstream uses two docker containers at two private IPs, port 8000 each.
    # Here both are host processes on HOST_IP (private), on two ports; the
    # policy's fixed `port: 8000` becomes one port per endpoint.
    explicit = Fixture(fx("b_explicit_allowed_ips_server.py"))
    implicit = Fixture(fx("b_explicit_allowed_ips_server.py"))
    try:
        WS.ensure(render("b_explicit_allowed_ips_policy.yaml", EXPLICIT_IP=HOST_IP, EXPLICIT_PORT=explicit.port,
                         IMPLICIT_IP=HOST_IP, IMPLICIT_PORT=implicit.port))
        for mode, port in (("explicit_allowed_ips", explicit.port), ("implicit_ip_literal", implicit.port)):
            result = parse_json_line(guest(["python3", "-c", status_script(HOST_IP, port)]))
            check(status_is(result.get("first"), 200) and status_is(result.get("second"), 200),
                  f"{mode} ({HOST_IP}:{port}): {result}")
    finally:
        explicit.close()
        implicit.close()


@case("proxy_egress_pipeline::tls_skip_connect_relays_opaque_bytes_bidirectionally", PE)
def tls_skip_relay():
    server = TcpServer(echo)
    try:
        out = create(pe_policy(server.port, "        tls: skip"),
                     ["python3", "-c", render("b_tls_skip_connect_client.py", PORT=server.port)])
        check("RAW_RELAY_OK" in out, tail(out))
    finally:
        server.close()


@case("proxy_egress_pipeline::middleware_redacts_transparent_request_bodies", PE)
def middleware_redacts():
    server = TcpServer(request_body_echo)
    try:
        out = create(middleware_policy(server.port, "", "fail_closed"),
                     ["python3", "-c", render("b_middleware_redacts_client.py", PORT=server.port)])
        result = parse_json_line(out)
        for key in ("first", "second"):
            check(result.get(key, {}).get("api_key") == "[REDACTED]", f"{key}: {result.get(key)}; {tail(out)}")
        leaked = [r for r in server.records if b"sk-1234567890abcdef" in r]
        check(not leaked, f"upstream received the unredacted secret: {leaked!r}")
    finally:
        server.close()


@case("proxy_egress_pipeline::fail_closed_middleware_blocks_uninspectable_transparent_payload_before_upstream", PE)
def fail_closed_middleware():
    # Dropped: the log assertion on OpenShell's OCSF wording
    # (`openshell.middleware.traffic_uninspectable`, "Unsupported tunnel
    # protocol cannot be inspected by required middleware"). The functional
    # checks (client blocked, upstream saw zero bytes) are kept.
    server = TcpServer(echo)
    try:
        WS.ensure(middleware_policy(server.port, "", "fail_closed"))
        out = guest(["python3", "-c", render("b_fail_closed_middleware_client.py", PORT=server.port)])
        time.sleep(0.2)
        check("UNINSPECTABLE_MIDDLEWARE_BLOCKED" in out, tail(out))
        check(observed(server) == b"", f"upstream saw bytes: {observed(server)!r}")
    finally:
        server.close()


@case("proxy_egress_pipeline::fail_open_middleware_bypasses_uninspectable_transparent_tls_skip", PE)
def fail_open_middleware():
    server = TcpServer(echo)
    try:
        out = create(middleware_policy(server.port, "        tls: skip", "fail_open"),
                     ["python3", "-c", render("b_fail_open_middleware_client.py", PORT=server.port)])
        check("UNINSPECTABLE_MIDDLEWARE_BYPASSED" in out, tail(out))
        want = bytes([0x00, 0xFF, 0x13, 0x37, 0x80]) + b"middleware-bypass"
        check(observed(server) == want, f"upstream observed {observed(server)!r}, expected {want!r}")
    finally:
        server.close()


@case("proxy_egress_pipeline::transparent_pipeline_never_reaches_upstream_as_first_request_overflow", PE)
def pipeline_overflow():
    server = TcpServer(pipeline_probe)
    try:
        out = create(pe_policy(server.port, options("b_transparent_pipeline_options.yaml")),
                     ["python3", "-c", render("b_transparent_pipeline_client.py", PORT=server.port)])
        seen = observed(server)
        check("TRANSPARENT_PIPELINE_DENIED" in out, tail(out))
        check(seen.startswith(b"GET /allowed HTTP/1.1\r\n"), f"upstream observed {seen!r}")
        check(b"\r\nconnection:" not in seen.lower(),
              f"hop-by-hop Connection header forwarded upstream: {seen!r}")
        check(b"/blocked" not in seen, f"blocked pipelined request reached the upstream: {seen!r}")
    finally:
        server.close()


@case("proxy_egress_pipeline::chunked_pipeline_is_authorized_separately_before_reaching_upstream", PE)
def chunked_pipeline():
    server = TcpServer(pipeline_probe)
    try:
        out = create(pe_policy(server.port, options("b_chunked_pipeline_options.yaml")),
                     ["python3", "-c", render("b_chunked_pipeline_client.py", PORT=server.port)])
        seen = observed(server)
        check("CHUNKED_PIPELINE_DENIED" in out, tail(out))
        check(seen.startswith(b"POST /allowed HTTP/1.1\r\n"), f"upstream observed {seen!r}")
        check(seen.endswith(b"0\r\n\r\n"), f"chunked terminator missing or followed by bytes: {seen!r}")
        check(b"/blocked" not in seen, f"blocked pipelined request reached the upstream: {seen!r}")
    finally:
        server.close()


PE_SECRET = "sk-e2e-proxy-egress-secret"
PE_CREDS = CredentialWorkspace("E2E OpenShell Creds Egress")
PE_CREDENTIAL_OPTIONS = """        path: /probe
        protocol: rest
        enforcement: enforce
        request_body_credential_rewrite: true
        access: full"""


def credential_probe(conn: socket.socket, server: TcpServer) -> None:
    """CredentialProbeServer."""
    req = read_http_request(conn)
    if req is None:
        return
    server.record(req)
    head, _, body = req.partition(b"\r\n\r\n")
    header_resolved = any(k.strip().lower() == b"authorization" and v.strip() == f"Bearer {PE_SECRET}".encode()
                          for k, _, v in (line.partition(b":") for line in head.split(b"\r\n")[1:]))
    doc = {"body_resolved": PE_SECRET.encode() in body, "header_resolved": header_resolved,
           "saw_placeholder": PLACEHOLDER_PREFIX.encode() in req}
    payload = json.dumps(doc, separators=(",", ":"), sort_keys=True).encode()
    conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                 + str(len(payload)).encode() + b"\r\nConnection: close\r\n\r\n" + payload)


@case("proxy_egress_pipeline::http_credentials_are_rewritten_in_transparent_headers_and_bodies", PE)
def credentials_rewritten():
    # Partial: OpenShell's provider profile + `provider create --credential
    # PROXY_E2E_TOKEN=...` + `--provider` become one Bromure manual token on a
    # dedicated workspace with `openShellCredentialPlaceholders`: env
    # PROXY_E2E_TOKEN, bound to HOST_NAME, path /probe (the profile endpoint).
    # The policy is PE-BASE with upstream's endpoint options,
    # `request_body_credential_rewrite: true` kept. Dropped: provider/profile
    # CRUD and cleanup. Added (Bromure-side control, not upstream): with the
    # opt-in removed the header is still resolved but the body is not.
    server = TcpServer(credential_probe)
    try:
        PE_CREDS.ensure_with_credentials(pe_policy(server.port, PE_CREDENTIAL_OPTIONS), [
            manual_token("proxy_e2e_token", PE_SECRET, "PROXY_E2E_TOKEN", [HOST_NAME], ["/probe"])])
        PE_CREDS.check_placeholder_env("PROXY_E2E_TOKEN")
        script = render("b_http_credentials_client.py", PORT=server.port)
        r = PE_CREDS.workload(["python3", "-c", script])
        out = r.out + r.err
        check(r.rc == 0, f"workload exited {r.rc}: {tail(out)}")
        result = parse_json_line(out)
        for key in ("first", "second"):
            got = result.get(key, {})
            check(got.get("header_resolved") is True, f"{key}: Authorization placeholder not resolved: {got}")
            check(got.get("body_resolved") is True, f"{key}: body placeholder not resolved: {got}")
            check(got.get("saw_placeholder") is False, f"{key}: placeholder reached the upstream: {got}")
        check(PE_SECRET not in out, "the secret appeared in the guest output")
        check(PLACEHOLDER_PREFIX not in out, f"the placeholder appeared in the guest output: {tail(out)}")

        # Control: the same requests on an endpoint without the body opt-in.
        opt_in = "        request_body_credential_rewrite: true\n"
        no_body = pe_policy(server.port, PE_CREDENTIAL_OPTIONS)
        check(opt_in in no_body, "policy drifted: request_body_credential_rewrite not found")
        PE_CREDS.set_policy(no_body.replace(opt_in, ""))
        r = PE_CREDS.workload(["python3", "-c", script])
        out = r.out + r.err
        check(r.rc == 0, f"[no body opt-in] workload exited {r.rc}: {tail(out)}")
        result = parse_json_line(out)
        for key in ("first", "second"):
            got = result.get(key, {})
            check(got.get("header_resolved") is True, f"[no body opt-in] {key}: header not resolved: {got}")
            check(got.get("body_resolved") is False, f"[no body opt-in] {key}: body resolved without opt-in: {got}")
        check(PE_SECRET not in out, "[no body opt-in] the secret appeared in the guest output")
    finally:
        server.close()
        PE_CREDS.stop()


# ---------------------------------------------------------------- transparent_tcp.rs

@case("transparent_tcp::rootless_podman_musl_getaddrinfo_uses_udp_policy_dns", TT)
def musl_policy_dns():
    raise NotApplicable("podman-only upstream (skipped unless OPENSHELL_E2E_DRIVER=podman); tests OpenShell's "
                        "synthetic policy DNS (198.18.0.0/15) with a zig-built musl probe and `sandbox upload`")


@case("transparent_tcp::local_container_native_tcp_uses_policy_dns_and_fails_closed", TT)
def native_tcp_fails_closed():
    # Docker branch of the upstream test (host-process fixture, free host
    # ports, policy host = the host alias, real_ip = 127.0.0.1).
    # Dropped:
    #  - the synthetic-DNS assertion (getaddrinfo answers in 198.18.0.0/15):
    #    OpenShell-only; Bromure resolves real IPs and snoops DNS. Replaced
    #    with "resolves successfully".
    #  - the log assertions ("-> host:port", "Denied staged transparent
    #    connection"): OpenShell supervisor wording.
    # Note: as upstream's docker branch, real_ip 127.0.0.1 is the guest's own
    # loopback, so the two real-IP denials are effectively loopback checks.
    fixture_port, tcp_dns_port, transparent_port, wrong_port = (free_port() for _ in range(4))
    fixture = HostPython(render("b_local_container_native_tcp_fixture.py", TRANSPARENT_PORT=transparent_port,
                                TCP_DNS_PORT=tcp_dns_port, FIXTURE_PORT=fixture_port), fixture_port)
    try:
        WS.ensure(render("b_transparent_tcp_policy.yaml", HOST=HOST_NAME,
                         PORTS_COMMA_SPACE=f"{fixture_port}, {tcp_dns_port}"))
        script = render("b_local_container_native_tcp_client.py", HOST_PY=py_str(HOST_NAME),
                        FIXTURE_PORT=fixture_port, TCP_DNS_PORT=tcp_dns_port, WRONG_PORT=wrong_port,
                        REAL_IP_PY=py_str("127.0.0.1"), TRANSPARENT_PORT=transparent_port)
        synthetic = ("assert any(ip.startswith('198.18.') or ip.startswith('198.19.') for ip in synthetic), "
                     "synthetic")
        check(synthetic in script, "fixture drifted: synthetic-DNS assertion not found")
        script = script.replace(synthetic, "assert synthetic, synthetic")
        out = guest(["python3", "-c", script])
        check("transparent-tcp-e2e-ok" in out, tail(out))
    finally:
        fixture.close()


# ---------------------------------------------------------------- live_policy_update.rs

def _lpu(*hosts: str) -> str:
    """write_policy(hosts): one rule_i per host."""
    base = render("b_live_policy_update_lpu.yaml", HOST0=hosts[0])
    for i, host in enumerate(hosts[1:], start=1):
        base += (f"  rule_{i}:\n    name: rule_{i}\n    endpoints:\n      - host: {host}\n        port: 443\n"
                 f"    binaries:\n      - path: \"/**\"\n")
    return base


_HTTP_CODE = "curl -s -o /dev/null -w '%{http_code}' -m 15 https://{host}/ || true"


def _http_code(host: str) -> str:
    return WS.sh(_HTTP_CODE.replace("{host}", host), timeout=40).out.strip()[-3:]


@case("live_policy_update::l7_append_target_scope_round_trip", LPU)
def l7_append_scope():
    raise NotApplicable("`openshell policy update --add-allow/--add-deny` incremental merge and "
                        "`policy get --full --output json` revisions have no Bromure equivalent")


@case("live_policy_update::live_policy_update_round_trip", LPU)
def live_update_round_trip():
    raise NotApplicable("asserts OpenShell's gateway revision store (Version/Hash from `policy get`, "
                        "`policy list` history); Bromure keeps no policy revisions")


@case("live_policy_update::live_policy_update_from_empty_network_policies", LPU)
def live_update_from_empty():
    # Partial: the upstream assertion is a revision bump (`new_version >
    # initial_version`), which Bromure does not model. Kept: a workspace
    # started with no network_policies key accepts the live update, and the
    # update takes effect (example.com goes from denied to reachable).
    WS.ensure(render("b_live_policy_update_empty.yaml"))
    before = _http_code("example.com")
    WS.set_policy(_lpu("example.com"))
    after = _http_code("example.com")
    check(before in ("000", "403"), f"example.com reachable before the update (HTTP {before})")
    check(after.startswith(("2", "3")), f"example.com not reachable after the live update (HTTP {after})")


@case("live_policy_update::initial_sparse_policy_is_acknowledged_as_loaded", LPU)
def sparse_policy_loaded():
    # Partial: upstream waits for revision 2 (supervisor filesystem enrichment)
    # to be Loaded with no Pending entry in `policy list` — OpenShell revision
    # machinery. Kept (spec's portable form): a sparse network-only policy (no
    # filesystem section, no binaries key) is accepted, the workspace runs,
    # and the policy is effective: the listed host answers, others are denied.
    WS.ensure(fx("b_initial_sparse_policy_policy.yaml"))
    check(WS.exec(["/bin/echo", "ready"]).out.strip() == "ready", "workspace not running the sparse policy")
    listed = _http_code("api.anthropic.com")
    other = _http_code("example.com")
    check(listed not in ("000", "403"), f"api.anthropic.com not reachable under the sparse policy (HTTP {listed})")
    check(other in ("000", "403"), f"example.com reachable under the sparse policy (HTTP {other})")


# ---------------------------------------------------------------- policy_activation.rs

@case("policy_activation::invalid_image_provider_bundle_waits_for_repair_before_launch", PA)
def policy_activation():
    raise NotApplicable("custom `--from` OCI image with an embedded policy, provider/profile CRUD, docker "
                        "container labels/RestartCount and `sandbox get` phase/conditions")


# ---------------------------------------------------------------- credential_gating.rs

@case("credential_gating::credentialed_endpoint_gates_work_end_to_end", CG)
def credential_gating():
    raise NotApplicable("OpenShell providers/profiles, `openshell:resolve:env:` placeholders, "
                        "credential_binding/allow_uninspected_credentials admission and per-exec env injection — "
                        "Bromure brokers credentials with its own host-side token swap")


# ---------------------------------------------------------------- host_gateway_alias.rs

def _host_server(body: bytes):
    """HostServer.start (no auth check): headers only, then the JSON body."""
    def handler(conn: socket.socket, server: TcpServer) -> None:
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = conn.recv(4096)
            if not chunk:
                break
            data += chunk
        server.record(data)
        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                     + str(len(body)).encode() + b"\r\nConnection: close\r\n\r\n" + body)
        conn.shutdown(socket.SHUT_RDWR)
    return handler


def _hga_policy(port: int) -> str:
    return render("b_host_gateway_alias_policy.yaml", PORT=port)


@case("host_gateway_alias::sandbox_reaches_host_openshell_internal_via_host_gateway_alias", HGA)
def host_alias_reachable():
    server = TcpServer(_host_server(b'{"message":"hello-from-host"}'))
    try:
        cmd = render("b_sandbox_reaches_host_cmd.sh", PORT=server.port).strip("\n")
        out = create(_hga_policy(server.port), ["/usr/bin/bash", "-c", cmd])
        check('"message":"hello-from-host"' in out, tail(out))
    finally:
        server.close()


EOF_RESPONSES = (
    b"HTTP/1.0 200 OK\r\nContent-Length: 3\r\n\r\nOK\n",
    b"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 3\r\n\r\nOK\n",
    b"HTTP/1.1 200 OK\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nOK\n\r\n0\r\n\r\n",
)


def _one_shot(response: bytes):
    def handler(conn: socket.socket, server: TcpServer) -> None:
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        request = b""
        while not request.endswith(b"\r\n\r\n"):
            byte = conn.recv(1)
            if not byte:
                break
            request += byte
            if len(request) >= 4096:
                break
        server.record(request)
        conn.sendall(response)
        conn.shutdown(socket.SHUT_WR)
    return handler


@case("host_gateway_alias::sandbox_receives_eof_after_closing_http_response", HGA)
def eof_after_closing_response():
    # `--no-auto-providers` is an OpenShell CLI flag with no Bromure meaning.
    for response in EOF_RESPONSES:
        framing = response.split(b"\r\n\r\n", 1)[0].decode()
        server = TcpServer(_one_shot(response))
        try:
            WS.ensure(_hga_policy(server.port))
            r = WS.exec(["/usr/bin/bash", "-c", render("b_sandbox_receives_eof_cmd.sh", PORT=server.port)],
                        timeout=60)
            out = r.out + r.err
            check(r.rc == 0, f"[{framing!r}] exited {r.rc}: {tail(out)}")
            check(any(line == "OK" for line in out.splitlines()), f"[{framing!r}] no `OK` line: {tail(out)}")
            check("RESPONSE_EOF" in out, f"[{framing!r}] no RESPONSE_EOF: {tail(out)}")
            check("EOF_TIMEOUT" not in out, f"[{framing!r}] EOF never propagated: {tail(out)}")
            requests = server.records
            check(requests and len(requests[0]) < 4096, f"[{framing!r}] upstream request: {requests!r}")
        finally:
            server.close()


BOUND_SECRET = "e2e-bound-secret"
PROVIDER_B_SECRET = "e2e-provider-b-secret"
BINDING_CREDS = CredentialWorkspace("E2E OpenShell Creds Binding")
# OpenShell's `host.docker.internal`: a second name for the same host server.
ALT_HOST = HOST_IP if HOST_NAME != HOST_IP else HOST_IP + ".sslip.io"


def _auth_check_server(expected_auth: str):
    """HostServer.start_with_auth_check("", Some(expected)): headers only,
    `{"authorized":true|false}` by a whole-line Authorization match."""
    want = f"authorization: {expected_auth}".lower().encode()

    def handler(conn: socket.socket, server: TcpServer) -> None:
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = conn.recv(4096)
            if not chunk:
                break
            data += chunk
        server.record(data)
        ok = any(line.strip().lower() == want for line in data.split(b"\r\n"))
        body = b'{"authorized":true}' if ok else b'{"authorized":false}'
        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                     + str(len(body)).encode() + b"\r\nConnection: close\r\n\r\n" + body)
        conn.shutdown(socket.SHUT_RDWR)
    return handler


@case("host_gateway_alias::static_provider_credentials_are_bound_to_profile_endpoints", HGA)
def static_provider_binding():
    # Partial: the two provider profiles (A bound to host.openshell.internal
    # /allowed/**, B to host.docker.internal /allowed/**) become two Bromure
    # manual tokens on a dedicated workspace with
    # `openShellCredentialPlaceholders`: BOUND_TOKEN_A on HOST_NAME
    # /allowed/**, BOUND_TOKEN_B on ALT_HOST (the Mac's second name) /allowed/**.
    # The policy is upstream's plus allowed_ips covering the Mac (Bromure's
    # private-IP guard, like the other host-alias policies).
    # Dropped: provider/profile CRUD, `--no-auto-providers`, and the log
    # assertions (OCSF `openshell.provider_credential.endpoint_mismatch` /
    # `credential_endpoint_mismatch`, and no secret / env name in the logs):
    # OpenShell supervisor event names with no Bromure log route here.
    # Divergence accepted: OpenShell answers 403 on both mismatches. Bromure
    # blocks the placeholder bound for the other host as a credential leak
    # (451), and on the bound host's other path forwards it unresolved (the
    # upstream sees a useless placeholder). Either way the secret must never
    # reach the upstream outside /allowed/** on HOST_NAME — checked
    # upstream-side.
    server = TcpServer(_auth_check_server(f"Bearer {BOUND_SECRET}"))
    try:
        policy = render("b_static_binding_policy.yaml", PORT=server.port).replace("host.docker.internal", ALT_HOST)
        BINDING_CREDS.ensure_with_credentials(policy, [
            manual_token("bound_token_a", BOUND_SECRET, "BOUND_TOKEN_A", [HOST_NAME], ["/allowed/**"]),
            manual_token("bound_token_b", PROVIDER_B_SECRET, "BOUND_TOKEN_B", [ALT_HOST], ["/allowed/**"])])
        BINDING_CREDS.check_placeholder_env("BOUND_TOKEN_A")
        BINDING_CREDS.check_placeholder_env("BOUND_TOKEN_B")
        cmd = render("b_static_binding_cmd.sh", PORT=server.port)
        check("host.docker.internal" in cmd, "fixture drifted: host.docker.internal not found")
        cmd = cmd.replace("host.docker.internal", ALT_HOST)
        r = BINDING_CREDS.workload(["/usr/bin/bash", "-c", cmd])
        out = r.out + r.err
        check(r.rc == 0, f"workload exited {r.rc}: {tail(out)}")
        line = next((l for l in out.splitlines() if l.startswith("ALLOWED=")), None)
        check(line is not None, f"no ALLOWED= line: {tail(out)}")
        check('ALLOWED={"authorized":true}' in line, f"bound host+path did not resolve the placeholder: {line}")
        host_denied = re.search(r"HOST_DENIED=(\S*)", line).group(1)
        path_denied = re.search(r"PATH_DENIED=(\S*)", line).group(1)
        check(host_denied in ("403", "451", "connect-denied"),
              f"placeholder to the unbound host {ALT_HOST} was not denied (HOST_DENIED={host_denied!r}): {line}")
        check(path_denied == "403", f"placeholder on the bound host but outside its path was not refused (PATH_DENIED={path_denied!r}): {line}")
        for secret in (BOUND_SECRET, PROVIDER_B_SECRET):
            check(secret not in out, f"the secret {secret} appeared in the guest output")

        requests = list(server.records)

        def first_line(req: bytes) -> bytes:
            return req.split(b"\r\n", 1)[0]

        def host_of(req: bytes) -> bytes:
            for l in req.split(b"\r\n")[1:]:
                k, _, v = l.partition(b":")
                if k.strip().lower() == b"host":
                    return v.strip().rsplit(b":", 1)[0].lower()
            return b""

        allowed = [q for q in requests if first_line(q).startswith(b"GET /allowed/check ")
                   and host_of(q) == HOST_NAME.lower().encode()]
        check(allowed and all(BOUND_SECRET.encode() in q and PLACEHOLDER_PREFIX.encode() not in q for q in allowed),
              f"upstream did not get the resolved secret on the bound endpoint: {allowed!r}")
        elsewhere = [q for q in requests if q not in allowed]
        leaked = [q for q in elsewhere if BOUND_SECRET.encode() in q or PROVIDER_B_SECRET.encode() in q]
        check(not leaked, f"secret resolved outside its binding: {leaked!r}")
        to_alt = [q for q in requests if host_of(q) == ALT_HOST.lower().encode()]
        if host_denied != "403":
            check(not to_alt or all(BOUND_SECRET.encode() not in q for q in to_alt),
                  f"unbound host request reached the upstream with the secret: {to_alt!r}")
        if path_denied == "200":
            other = [q for q in requests if first_line(q).startswith(b"GET /other/check ")]
            check(other and all(BOUND_SECRET.encode() not in q for q in other),
                  f"other-path request carried the secret upstream: {other!r}")
    finally:
        server.close()
        BINDING_CREDS.stop()
