"""Replay OpenShell's end-to-end scenarios against real Bromure workspaces.

OpenShell's own e2e suites (e2e/rust, e2e/python) drive sandboxes through its
gateway and CLI. This module gives the ported scenarios the same primitives on
top of a Bromure Agentic Coding instance: a workspace per policy, commands run
inside it, live policy updates, and host-side upstream servers the workspace
reaches the way an OpenShell sandbox reaches `host.openshell.internal`.

Environment:
  BROMURE_AC        path to the signed bromure-ac binary inside the .app
  CFFIXED_USER_HOME the isolated test instance's home (never the real one)
  E2E_HOST_IP       the Mac's LAN address the guest can reach (default: en0)
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import threading
import time
import traceback
import urllib.parse
import uuid
from dataclasses import dataclass, field
from typing import Callable

BIN = os.environ.get("BROMURE_AC", "")
HOME = os.environ.get("CFFIXED_USER_HOME", "")
SOCK = os.path.join(HOME, "Library/Application Support/BromureAC/control.sock")


def _host_ip() -> str:
    if os.environ.get("E2E_HOST_IP"):
        return os.environ["E2E_HOST_IP"]
    for iface in ("en0", "en1"):
        out = subprocess.run(["ipconfig", "getifaddr", iface], capture_output=True, text=True).stdout.strip()
        if out:
            return out
    raise RuntimeError("no LAN address; set E2E_HOST_IP")


HOST_IP = _host_ip()
# OpenShell's `host.openshell.internal`: how the workload addresses the host.
# "name" (default) = a nip.io name resolving to the host, like OpenShell's
# host alias; "ip" = the address itself, like OpenShell's docker lane (which
# hands the sandbox the fixture container's bridge IP).
HOST_MODE = os.environ.get("E2E_HOST_MODE", "name")
HOST_NAME = HOST_IP if HOST_MODE == "ip" else HOST_IP.replace(".", "-") + ".nip.io"
# OpenShell's workdir is /sandbox; Bromure's is the workspace home.
WORKDIR = "/home/ubuntu"

# The OpenShell template's filesystem/landlock sections (e2e/python/_BASE_*),
# with /sandbox mapped to the Bromure home.
BASE_SANDBOX = f"""filesystem_policy:
  include_workdir: true
  read_only: [/usr, /lib, /etc, /app, /var/log, /proc, /dev/urandom, /bin]
  read_write: [{WORKDIR}, /tmp, /dev/null]
landlock:
  compatibility: best_effort
"""


def control(method: str, path: str, body: dict | None = None, timeout: int = 30) -> dict:
    args = ["curl", "-s", "-m", str(timeout), "--unix-socket", SOCK, "-X", method, f"http://x{path}"]
    if body is not None:
        args += ["-H", "Content-Type: application/json", "--data-binary", json.dumps(body)]
    out = subprocess.run(args, capture_output=True, text=True).stdout
    try:
        return json.loads(out or "{}")
    except json.JSONDecodeError:
        return {"raw": out}


def cli(*args: str, timeout: int = 120) -> subprocess.CompletedProcess:
    env = dict(os.environ, CFFIXED_USER_HOME=HOME)
    return subprocess.run([BIN, *args], capture_output=True, text=True, timeout=timeout, env=env)


@dataclass
class Result:
    rc: int
    out: str
    err: str

    def __str__(self) -> str:
        return f"rc={self.rc} out={self.out.strip()[:300]!r} err={self.err.strip()[:300]!r}"


def _sandbox_sections(policy: str) -> str:
    """The part of a policy that only applies at VM start: the top-level
    filesystem_policy / landlock / process blocks, as text."""
    blocks: dict[str, list[str]] = {}
    current = None
    for line in policy.splitlines():
        if line and not line[0].isspace() and not line.startswith("#"):
            key = line.split(":", 1)[0].strip()
            current = key if key in ("filesystem_policy", "landlock", "process") else None
        if current:
            blocks.setdefault(current, []).append(line.rstrip())
    return json.dumps({k: "\n".join(v) for k, v in sorted(blocks.items())})


# Bromure's per-provider consent prompts (GitHub, AWS, …) would stop an
# unattended run on a modal; the OpenShell policy is what's under test.
GUARDRAILS_OFF = {k: "off" for k in ("aws", "bitbucket", "digitalOcean", "docker", "github", "gitlab", "kubernetes")}


class Workspace:
    """One Bromure workspace, reused across scenarios that share its sandbox
    sections (network rules apply live; filesystem/process need a restart)."""

    def __init__(self, name: str):
        self.name = name
        self.policy = ""
        self.sections = None

    def _quoted(self) -> str:
        return urllib.parse.quote(self.name)

    def ensure(self, policy: str, sentry: str = "off") -> None:
        existing = control("GET", f"/profiles/{self._quoted()}?full=1")
        doc = existing.get("profile", existing)
        if not doc.get("name"):
            r = control("POST", "/profiles", {"name": self.name, "tool": "claude", "authMode": "subscription",
                                              "networkPolicy": policy, "kernelSentry": sentry,
                                              "openShellAdvisorMode": "off", "watchdogMode": "alert",
                                              "guardrails": GUARDRAILS_OFF})
            if not r.get("name"):
                raise RuntimeError(f"create {self.name}: {r}")
            self.sections = None
        sections = _sandbox_sections(policy)
        needs_restart = self.sections is not None and sections != self.sections
        self.set_policy(policy)
        if needs_restart:
            self.stop()
        self.sections = sections
        self.start()

    def set_policy(self, policy: str) -> None:
        doc = control("GET", f"/profiles/{self._quoted()}?full=1")
        doc = doc.get("profile", doc)
        doc["networkPolicy"] = policy
        doc["guardrails"] = GUARDRAILS_OFF
        r = control("PUT", f"/profiles/{self._quoted()}", doc)
        if r.get("ok") is False:
            raise RuntimeError(f"policy rejected: {r.get('error')}")
        self.policy = policy
        time.sleep(1.0)  # let the live update reach the proxy

    def running(self) -> bool:
        out = cli("vm", "ls").stdout
        return any(self.name in line and " running " in line for line in out.splitlines())

    def start(self) -> None:
        if not self.running():
            cli("vm", "run", self.name)
        deadline = time.time() + 240
        while time.time() < deadline:
            if self.exec(["/bin/echo", "ready"], timeout=25).out.strip() == "ready":
                return
            time.sleep(3)
        raise RuntimeError(f"{self.name} never became ready")

    def stop(self) -> None:
        cli("vm", "kill", self.name)
        time.sleep(4)

    def exec(self, argv: list[str], timeout: int = 60) -> Result:
        try:
            p = cli("vm", "exec", self.name, "--", *argv, timeout=timeout + 15)
            return Result(p.returncode, p.stdout, p.stderr)
        except subprocess.TimeoutExpired:
            return Result(-9, "", "timeout")

    def sh(self, script: str, timeout: int = 60) -> Result:
        return self.exec(["bash", "-c", script], timeout=timeout)

    def py(self, code: str, timeout: int = 60) -> Result:
        return self.exec(["python3", "-c", code], timeout=timeout)


# OpenShell credential placeholders (`openShellCredentialPlaceholders` on the
# workspace): the guest's env var holds `openshell:resolve:env:<VAR>` and the
# host proxy resolves it, scoped to the manual token's host / path filters.
PLACEHOLDER_PREFIX = "openshell:resolve:env:"
# The host writes credential env exports into the meta share (api_key.env;
# manual_tokens.env is sourced too in case it is split out). Used only when a
# plain `vm exec` environment does not already carry them.
META_ENV_SOURCE = ('for f in /mnt/bromure-meta/api_key.env /mnt/bromure-meta/manual_tokens.env; do '
                   'if [ -r "$f" ]; then set -a; . "$f" >/dev/null 2>&1; set +a; fi; done; ')


def manual_token(name: str, secret: str, env_var: str, hosts: list[str], paths: list[str] | None = None) -> dict:
    """A workspace `manualTokens` entry (Profile.swift ManualToken). `realValue`
    rides the control-socket PUT and is moved into the secrets blob host-side."""
    return {"id": str(uuid.uuid4()).upper(), "name": name, "realValue": secret, "envVarName": env_var,
            "hostFilters": list(hosts), "pathFilters": list(paths or []), "envVarAliases": [],
            "requireApproval": False}


class CredentialWorkspace(Workspace):
    """A workspace carrying manual-token credentials exposed to the guest as
    OpenShell placeholders. Its own workspace so the credentials never reach
    the other scenarios. Credentials apply at VM start, so every
    `ensure_with_credentials` restarts the VM."""

    def __init__(self, name: str):
        super().__init__(name)
        self.env_source = ""

    def ensure_with_credentials(self, policy: str, tokens: list[dict]) -> None:
        existing = control("GET", f"/profiles/{self._quoted()}?full=1")
        if not existing.get("profile", existing).get("name"):
            r = control("POST", "/profiles", {"name": self.name, "tool": "claude", "authMode": "subscription",
                                              "networkPolicy": policy, "kernelSentry": "off",
                                              "openShellAdvisorMode": "off", "watchdogMode": "alert",
                                              "guardrails": GUARDRAILS_OFF})
            if not r.get("name"):
                raise RuntimeError(f"create {self.name}: {r}")
        doc = control("GET", f"/profiles/{self._quoted()}?full=1")
        doc = doc.get("profile", doc)
        doc["networkPolicy"] = policy
        doc["guardrails"] = GUARDRAILS_OFF
        doc["openShellCredentialPlaceholders"] = True
        # A placeholder sent to an unbound host trips the exfiltration alarm;
        # with the alert on, the VM is paused behind a host modal. The leak is
        # still blocked (451) and logged with the alert off.
        doc["disableExfiltrationAlerts"] = True
        doc["manualTokens"] = tokens
        r = control("PUT", f"/profiles/{self._quoted()}", doc)
        if r.get("ok") is False:
            raise RuntimeError(f"credential workspace rejected: {r.get('error')}")
        stored = control("GET", f"/profiles/{self._quoted()}?full=1")
        stored = stored.get("profile", stored)
        check(stored.get("openShellCredentialPlaceholders") is True,
              f"{self.name}: openShellCredentialPlaceholders did not stick")
        stored_vars = sorted(t.get("envVarName", "") for t in stored.get("manualTokens", []))
        check(stored_vars == sorted(t["envVarName"] for t in tokens),
              f"{self.name}: manualTokens did not stick: {stored_vars}")
        self.policy = policy
        self.sections = _sandbox_sections(policy)
        if self.running():
            self.stop()
        self.start()

    def check_placeholder_env(self, var: str) -> None:
        """First assertion of every credential scenario: the workload sees the
        OpenShell placeholder in `$VAR`, not the secret. Falls back to sourcing
        the meta share's env files when `vm exec` doesn't carry them."""
        want = PLACEHOLDER_PREFIX + var
        probe = f'printf "%s" "${{{var}:-}}"'
        if self.sh(probe).out == want:
            self.env_source = ""
            return
        r = self.sh(META_ENV_SOURCE + probe)
        check(r.out == want, f"guest ${var} is {r.out[:80]!r} (with the meta env sourced), expected {want!r}")
        self.env_source = META_ENV_SOURCE

    def workload(self, argv: list[str], timeout: int = 120) -> Result:
        """Run argv with the credential env in place; `exec` keeps argv[0] the
        process that connects (binary-scoped policies)."""
        if self.env_source:
            argv = ["bash", "-c", self.env_source + 'exec "$@"', "workload", *argv]
        return self.exec(argv, timeout=timeout)


# ---------------------------------------------------------------- upstreams

class TcpServer:
    """A host-side TCP server on 0.0.0.0 that the workspace reaches at
    HOST_IP / HOST_NAME. `handler(conn, server)` serves one connection."""

    def __init__(self, handler: Callable[[socket.socket, "TcpServer"], None]):
        self.handler = handler
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("0.0.0.0", 0))
        self.sock.listen(64)
        self.port = self.sock.getsockname()[1]
        self.connections = 0
        self.records: list[bytes] = []
        self.lock = threading.Lock()
        self._stop = False
        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self) -> None:
        while not self._stop:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            with self.lock:
                self.connections += 1
            threading.Thread(target=self._serve, args=(conn,), daemon=True).start()

    def _serve(self, conn: socket.socket) -> None:
        try:
            conn.settimeout(20)
            self.handler(conn, self)
        except Exception:
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass

    def record(self, data: bytes) -> None:
        with self.lock:
            self.records.append(data)

    def close(self) -> None:
        self._stop = True
        self.sock.close()


def read_http_request(conn: socket.socket) -> bytes | None:
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(65536)
        if not chunk:
            return data or None
        data += chunk
    head, _, rest = data.partition(b"\r\n\r\n")
    length = 0
    for line in head.split(b"\r\n")[1:]:
        k, _, v = line.partition(b":")
        if k.strip().lower() == b"content-length":
            length = int(v.strip())
    while len(rest) < length:
        chunk = conn.recv(65536)
        if not chunk:
            break
        rest += chunk
    return head + b"\r\n\r\n" + rest


def http_response(status: int = 200, body: bytes = b"ok", headers: dict | None = None, close: bool = True) -> bytes:
    h = {"Content-Length": str(len(body)), "Content-Type": "text/plain"}
    if close:
        h["Connection"] = "close"
    h.update(headers or {})
    reason = {200: "OK", 403: "Forbidden", 404: "Not Found"}.get(status, "OK")
    return (f"HTTP/1.1 {status} {reason}\r\n" + "".join(f"{k}: {v}\r\n" for k, v in h.items()) + "\r\n").encode() + body


# ---------------------------------------------------------------- registry

@dataclass
class Case:
    id: str
    fn: Callable
    status: str = "pending"          # pass / fail / n/a / error
    detail: str = ""
    upstream_test: str = ""


CASES: list[Case] = []


def case(id: str, upstream: str = ""):
    def deco(fn):
        CASES.append(Case(id=id, fn=fn, upstream_test=upstream))
        return fn
    return deco


class NotApplicable(Exception):
    """The upstream test exercises an OpenShell product feature Bromure
    doesn't have (gateway API, providers, custom images...)."""


def check(cond: bool, msg: str) -> None:
    if not cond:
        raise AssertionError(msg)


def run(selected: list[str] | None = None, out_path: str = "results.json") -> int:
    failures = 0
    for c in CASES:
        if selected and not any(s in c.id for s in selected):
            continue
        t0 = time.time()
        try:
            c.fn()
            c.status = "pass"
        except NotApplicable as e:
            c.status, c.detail = "n/a", str(e)
        except AssertionError as e:
            c.status, c.detail = "fail", str(e)
            failures += 1
        except Exception as e:
            c.status, c.detail = "error", f"{e}\n{traceback.format_exc()[-800:]}"
            failures += 1
        print(f"[{c.status:5}] {c.id} ({time.time() - t0:.0f}s) {c.detail.splitlines()[0] if c.detail else ''}", flush=True)
    with open(out_path, "w") as f:
        json.dump([{k: getattr(c, k) for k in ("id", "status", "detail", "upstream_test")} for c in CASES
                   if not selected or any(s in c.id for s in selected)], f, indent=1)
    return failures
