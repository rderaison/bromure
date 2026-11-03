"""OpenShell e2e/python and e2e/policy-advisor, replayed against Bromure.

Every policy and callable is OpenShell's own, verbatim, from fixtures/py_*
(transcribed from e2e/python/test_*.py and e2e/policy-advisor/*; the Python
callables are stored dedented, otherwise unchanged; policies built from
sandbox_pb2 upstream are stored as the equivalent YAML). The only changes are
the harness's own: OpenShell's /sandbox workdir mapped to the Bromure
workspace home, and the documented divergences commented at each case.

`exec_python(fn, args)` upstream cloudpickles the callable and runs it as the
policy's process user; here the callable's source runs under `python3 -c` in
the workspace (as the `run_as_user: sandbox` user, uid 999, HOME=/home/ubuntu),
followed by `print(fn(*args))` when the result isn't None — the same output
contract as OpenShell's bootstrap. An exception exits non-zero with the
traceback on stderr, as upstream.
"""

from __future__ import annotations
import threading

import errno
import json
import os
import re
import textwrap
import time
import urllib.parse

from bromure_e2e import (BASE_SANDBOX, CASES, WORKDIR, NotApplicable, Result, Workspace, case, check,
                         control)
from scenarios_rust_a import WS, fx, localize

UPSTREAM_PY = "e2e/python"
UPSTREAM_ADVISOR = "e2e/policy-advisor"

# ---------------------------------------------------------------- helpers

_NOTES: list[str] = []


def note(msg: str) -> None:
    """Attach an observation to the running case's result (kept on pass)."""
    _NOTES.append(msg)


def pycase(id: str, upstream: str, partial: str = ""):
    """`case`, plus a `partial:` detail recorded on pass for scenarios that
    replay only part of the upstream test (the rest is explained there)."""
    def deco(fn):
        def wrapper():
            _NOTES.clear()
            fn()
            me.detail = "; ".join(([f"partial: {partial}"] if partial else []) + _NOTES)
        wrapper.__name__ = fn.__name__
        case(id, upstream)(wrapper)
        me = CASES[-1]
        return fn
    return deco


def not_applicable(id: str, upstream: str, reason: str) -> None:
    def fn():
        raise NotApplicable(reason)
    fn.__name__ = "na_" + re.sub(r"\W+", "_", id)
    case(id, upstream)(fn)


def exec_python(policy: str, fixture: str, fn_name: str, args: tuple = (), timeout: int = 60) -> Result:
    """OpenShell's `sandbox.exec_python(fn, args=...)` on the shared workspace."""
    WS.ensure(policy)
    src = localize(textwrap.dedent(fx(fixture)))
    code = (src + f"\n\n_result = {fn_name}(*{tuple(args)!r})\n"
            "if _result is not None:\n    print(_result)\n")
    return WS.py(code, timeout=timeout)


def policy_fx(name: str) -> str:
    return localize(fx(name))


# ======================================================= test_sandbox_landlock

LANDLOCK = "test_sandbox_landlock.py"
LANDLOCK_UP = f"{UPSTREAM_PY}/{LANDLOCK}"


def _landlock(fixture: str, path: str) -> Result:
    return exec_python(policy_fx("py_sandbox_landlock_policy.yaml"), fixture, "fn", (path,))


@pycase("test_sandbox_landlock::test_landlock_blocks_write_to_read_only_path", LANDLOCK_UP)
def landlock_blocks_write_ro():
    r = _landlock("py_sandbox_landlock_try_write.py", "/usr")
    check(r.rc == 0, r.err)
    check(r.out.strip() == "EPERM", str(r))


@pycase("test_sandbox_landlock::test_landlock_allows_write_to_read_write_path", LANDLOCK_UP)
def landlock_allows_write_rw():
    for path in ["/tmp", WORKDIR]:          # upstream: ["/tmp", "/sandbox"]
        r = _landlock("py_sandbox_landlock_try_write.py", path)
        check(r.rc == 0, f"{path}: {r.err}")
        check(r.out.strip() == "OK", f"{path}: {r}")


@pycase("test_sandbox_landlock::test_landlock_allows_read_on_read_only_path", LANDLOCK_UP)
def landlock_allows_read_ro():
    for path in ["/usr", "/etc"]:
        r = _landlock("py_sandbox_landlock_try_read.py", path)
        check(r.rc == 0, f"{path}: {r.err}")
        check(r.out.strip().startswith("OK:"), f"{path}: {r}")


@pycase("test_sandbox_landlock::test_landlock_blocks_access_outside_policy", LANDLOCK_UP)
def landlock_blocks_outside():
    for path in ["/opt", "/root"]:
        r = _landlock("py_sandbox_landlock_try_read.py", path)
        check(r.rc == 0, f"{path}: {r.err}")
        out = r.out.strip()
        check("EPERM" in out or "ERROR:" in out, f"{path}: {r}")


@pycase("test_sandbox_landlock::test_landlock_blocks_user_owned_path_outside_policy", LANDLOCK_UP)
def landlock_blocks_user_owned():
    # Upstream probes /home/sandbox: the `sandbox` user's own home in
    # OpenShell's image, owned by the workload and outside the policy, so only
    # Landlock (not file ownership) can refuse the write. Bromure's `sandbox`
    # user lives in /home/ubuntu instead, so the setup recreates the upstream
    # condition first: a boot with no sandbox sections (sudo still works)
    # creates /home/sandbox owned by the workload's uid. It persists on the
    # workspace disk into the sandboxed boot the test then runs in.
    WS.ensure("version: 1\nnetwork_policies: {}\n")
    made = WS.sh("u=$(id -u sandbox 2>/dev/null || echo 999); g=$(id -g sandbox 2>/dev/null || echo 991); "
                 "sudo -n install -d -m 0755 -o $u -g $g /home/sandbox && stat -c '%u' /home/sandbox")
    check(made.rc == 0, f"could not create /home/sandbox for the test: {made}")
    own = _landlock("py_sandbox_landlock_check_user_owns_path.py", "/home/sandbox")
    check(own.rc == 0 and "match:True" in own.out,
          f"/home/sandbox should be owned by the workload for this test: {own}")
    w = _landlock("py_sandbox_landlock_try_write.py", "/home/sandbox")
    check(w.rc == 0, w.err)
    check(w.out.strip() == "EPERM", str(w))


# ========================================================= test_sandbox_policy

POLICY = "test_sandbox_policy.py"
POLICY_UP = f"{UPSTREAM_PY}/{POLICY}"


@pycase("test_sandbox_policy::test_policy_applies_to_exec_commands", POLICY_UP)
def policy_applies_to_exec():
    policy = policy_fx("py_policy_applies_to_exec_commands_policy.yaml")
    r = exec_python(policy, "py_policy_applies_to_exec_commands_current_user.py", "current_user")
    check(r.rc == 0, r.err)
    check(r.out.strip() == "sandbox", str(r))
    r = exec_python(policy, "py_policy_applies_to_exec_commands_write_allowed_files.py", "write_allowed_files")
    check(r.rc == 0, r.err)
    check(r.out.strip() == "ok", str(r))


def _transparent_tcp(param: str) -> None:
    policy = policy_fx(f"py_transparent_tcp_policy_denies_unauthorized_connections_{param.replace('-', '_')}.yaml")
    t0 = time.time()
    r = exec_python(policy, "py_transparent_tcp_policy_denies_unauthorized_connections_connect.py",
                    "connect", ("1.1.1.1", 443))
    elapsed = time.time() - t0
    check(r.rc == 0, r.err)
    value = int(r.out.strip())
    # Documented divergence: OpenShell mediates the workload's sockets in the
    # sandbox, so an unauthorized connect() fails synchronously with EACCES or
    # EPERM. Bromure enforces at the host switch and refuses with a TCP RST,
    # which the guest sees as ECONNREFUSED (111). Either way connect() must
    # fail fast: a success (0) or a 5 s timeout (-1) still fails the case.
    allowed = {errno.EACCES, errno.EPERM, 111}
    check(value in allowed, f"connect to 1.1.1.1:443 returned {value} (want EACCES/EPERM, or ECONNREFUSED "
                            f"at Bromure's switch); {r}")
    name = {errno.EPERM: "EPERM", errno.EACCES: "EACCES", 111: "ECONNREFUSED"}.get(value, "?")
    note(f"errno={value} ({name}), exec+connect {elapsed:.1f}s")


@pycase("test_sandbox_policy::test_transparent_tcp_policy_denies_unauthorized_connections[no-policy]", POLICY_UP)
def transparent_tcp_no_policy():
    _transparent_tcp("no-policy")


@pycase("test_sandbox_policy::test_transparent_tcp_policy_denies_unauthorized_connections[wrong-port]", POLICY_UP)
def transparent_tcp_wrong_port():
    _transparent_tcp("wrong-port")


@pycase("test_sandbox_policy::test_transparent_tcp_policy_denies_unauthorized_connections[wrong-binary]", POLICY_UP)
def transparent_tcp_wrong_binary():
    # Binaries are enforced because the policy has a `process` section (it
    # turns on Bromure's strict sandbox, whose attestor names the executable).
    _transparent_tcp("wrong-binary")


# ------------------------------------------------ policy validation (save time)

def _reject(n: str, policy: str) -> str:
    """OpenShell rejects the policy at CreateSandbox; Bromure validates when a
    workspace's policy is saved. Create a throwaway workspace with it and
    return the refusal's text (deleting anything that got created)."""
    name = f"E2E validation {n}"
    path = f"/profiles/{urllib.parse.quote(name)}"
    control("DELETE", path)
    r = control("POST", "/profiles", {"name": name, "tool": "claude", "authMode": "subscription",
                                      "networkPolicy": policy})
    if r.get("ok") is not False or not r.get("error"):
        control("DELETE", path)
    check(r.get("ok") is False, f"policy was accepted: {json.dumps(r)[:600]}")
    err = str(r.get("error") or "")
    check(bool(err), f"rejected without an error message: {r}")
    note(f"error: {err[:300]}")
    return err


@pycase("test_sandbox_policy::test_conflicting_destination_metadata_is_rejected", POLICY_UP)
def conflicting_destination_metadata():
    # Upstream: FAILED_PRECONDITION "network endpoint ambiguity validation
    # failed: network policies 'approved_rule' endpoint[0] (10.200.0.2:19876)
    # and 'user_rule' endpoint[0] ... with conflicting metadata: allowed_ips=...".
    # Bromure (same check, ported): "network policies '...' endpoint[0] and
    # '...' endpoint[0] overlap on port(s) 19876 with conflicting metadata:
    # allowed_ips". Asserted: rejection naming the ambiguity and allowed_ips.
    err = _reject("ambiguity", policy_fx("py_conflicting_destination_metadata_is_rejected_policy.yaml"))
    low = err.lower()
    check("allowed_ips" in low, err)
    check("ambiguity" in low or "overlap" in low, err)


# ====================================================== test_policy_validation

VALIDATION = "test_policy_validation.py"
VALIDATION_UP = f"{UPSTREAM_PY}/{VALIDATION}"


@pycase("test_policy_validation::test_create_sandbox_rejects_root_user", VALIDATION_UP)
def rejects_root_user():
    # Upstream: INVALID_ARGUMENT "... run_as_user must be 'sandbox' or a numeric
    # UID/GID in range [1, 4294967294], got 'root'"; Bromure: "process.run_as_user:
    # must be 'sandbox' or a non-root numeric ID". Same keyword: "root".
    err = _reject("root user", policy_fx("py_create_sandbox_rejects_root_user_policy.yaml"))
    check("root" in err.lower(), err)


@pycase("test_policy_validation::test_create_sandbox_rejects_path_traversal", VALIDATION_UP)
def rejects_path_traversal():
    # Upstream: "path contains '..' traversal component: /usr/../etc/shadow"
    # (asserts "traversal"); Bromure: "filesystem_policy.read_only[0]: path must
    # not contain '..'". Same meaning, different wording: assert rejection and
    # that the message names the '..' component.
    err = _reject("traversal", policy_fx("py_create_sandbox_rejects_path_traversal_policy.yaml"))
    check("traversal" in err.lower() or ".." in err, err)


@pycase("test_policy_validation::test_create_sandbox_rejects_overly_broad_paths", VALIDATION_UP)
def rejects_overly_broad():
    # Upstream: "read-write path is overly broad: /" (asserts "broad"); Bromure:
    # "filesystem_policy.read_write[0]: read_write cannot contain /". Same rule
    # (a read-write `/`), different wording: assert rejection naming the
    # read-write `/` entry.
    err = _reject("broad", policy_fx("py_create_sandbox_rejects_overly_broad_paths_policy.yaml"))
    low = err.lower()
    check("broad" in low or (("read_write" in low or "read-write" in low) and "/" in err), err)


not_applicable(
    "test_policy_validation::test_create_sandbox_materializes_default_mcp_version", VALIDATION_UP,
    "Bromure stores the workspace's policy YAML verbatim (GET /profiles/<name>?full=1 returns the authored "
    "text) and the effective policy (policy.local /v1/policy/current) is that text plus provider rules; "
    "MCP defaults (versions [2025-11-25]) are applied at evaluation (OpenShellPolicy.MCPOptions), never "
    "materialized into a stored policy")

not_applicable(
    "test_policy_validation::test_update_policy_rejects_immutable_fields", VALIDATION_UP,
    "Bromure has no live-update rejection for filesystem/landlock/process: those sections are applied at "
    "the next VM start (a saved change restarts the workspace) rather than refused on a running sandbox; "
    "only network_policies apply live")


# ============================================================ test_security_tls

for _t in ("test_authenticated_client_succeeds", "test_no_client_cert_rejected",
           "test_wrong_client_cert_rejected", "test_plaintext_connection_rejected"):
    not_applicable(
        f"test_security_tls::TestServerMtlsEnforcement::{_t}", f"{UPSTREAM_PY}/test_security_tls.py",
        "OpenShell gateway gRPC mTLS transport test; Bromure has no gRPC gateway (its control channel is "
        "an owner-only Unix socket / SSH), so there is no client-certificate endpoint to exercise")


# =========================================================== test_exec_admission

_EXEC = ("OpenShell gateway ExecSandbox request-id admission/replay semantics (REQUEST_OUTCOME_UNCERTAIN, "
         "REQUEST_ID_PAYLOAD_MISMATCH, REQUEST_STREAM_UNAVAILABLE); Bromure's `vm exec` has no request-id "
         "admission layer")
for _t in ("test_exec_request_id_never_relaunches_or_replays_output[False]",
           "test_exec_request_id_never_relaunches_or_replays_output[True]",
           "test_exec_request_timeout_keeps_launch_unresolved[False]",
           "test_exec_request_timeout_keeps_launch_unresolved[True]",
           "test_exec_client_cancellation_does_not_clear_launch_admission"):
    not_applicable(f"test_exec_admission::{_t}", f"{UPSTREAM_PY}/test_exec_admission.py", _EXEC)


# ======================================================== test_sandbox_providers

PROVIDERS_UP = f"{UPSTREAM_PY}/test_sandbox_providers.py"
_PROVIDERS = {
    "test_provider_credentials_available_as_env_vars":
        "OpenShell provider credential placeholders (`openshell:resolve:env:KEY` in the sandbox env); Bromure "
        "brokers credentials with its own host-side stand-in swap configured per workspace, not providers",
    "test_profileless_provider_creation_is_rejected":
        "OpenShell provider catalog (provider profiles) CRUD; Bromure has no provider objects",
    "test_endpointless_profile_credentials_fail_closed_without_policy_binding":
        "OpenShell provider profiles / credential_binding of provider placeholders; no Bromure equivalent",
    "test_endpointless_profile_credentials_use_explicit_policy_binding":
        "OpenShell provider profiles / credential_binding of provider placeholders; no Bromure equivalent",
    "test_nvidia_provider_injects_nvidia_api_key_env_var":
        "OpenShell provider credential placeholders injected as env vars; no Bromure provider objects",
    "test_attach_detach_updates_credentials_for_later_exec_launches":
        "OpenShell AttachSandboxProvider/DetachSandboxProvider gateway API; no Bromure equivalent",
    "test_imported_openai_profile_allows_native_endpoint_with_attached_provider":
        "OpenShell ImportProviderProfiles + workspace-scoped provider profile + attached provider "
        "placeholder swap; no Bromure provider-profile import API",
    "test_imported_anthropic_profile_allows_native_endpoint_with_attached_provider":
        "OpenShell ImportProviderProfiles + workspace-scoped provider profile + attached provider "
        "placeholder swap; no Bromure provider-profile import API",
    "test_create_sandbox_rejects_unknown_provider":
        "OpenShell SandboxSpec.providers references; Bromure workspaces don't reference named providers",
    "test_credentials_not_in_persisted_spec_environment":
        "OpenShell GetSandbox persisted spec.environment of provider credentials; no Bromure provider objects",
    "test_update_provider_preserves_unset_credentials_and_config":
        "OpenShell UpdateProvider merge semantics (provider CRUD); no Bromure equivalent",
    "test_update_provider_empty_maps_preserves_all":
        "OpenShell UpdateProvider merge semantics (provider CRUD); no Bromure equivalent",
    "test_update_provider_merges_config_preserves_credentials":
        "OpenShell UpdateProvider merge semantics (provider CRUD); no Bromure equivalent",
    "test_update_provider_rejects_type_change":
        "OpenShell UpdateProvider type immutability (provider CRUD); no Bromure equivalent",
    "test_provider_profile_platform_vs_workspace_isolation":
        "OpenShell provider-profile catalog platform vs workspace scoping; no Bromure equivalent",
    "test_cross_workspace_profile_ids_do_not_collide":
        "OpenShell provider-profile catalog workspace scoping; no Bromure equivalent",
}
for _t, _why in _PROVIDERS.items():
    not_applicable(f"test_sandbox_providers::{_t}", PROVIDERS_UP, _why)


@pycase("test_sandbox_providers::test_github_provider_allows_https_git_clone", PROVIDERS_UP,
        partial="provider aspect dropped: the github provider's git rules are written into the policy "
                "explicitly (github_git) instead of composed from an attached provider; no token involved")
def github_https_git_clone():
    WS.ensure(policy_fx("py_github_provider_allows_https_git_clone_policy.yaml"))
    WS.exec(["rm", "-rf", "/tmp/hello-world"])      # upstream starts from a fresh sandbox
    clone = WS.exec(["git", "clone", "--depth", "1", "https://github.com/octocat/Hello-World.git",
                     "/tmp/hello-world"], timeout=120)
    check(clone.rc == 0, f"git clone: {clone}")
    head = WS.exec(["cat", "/tmp/hello-world/.git/HEAD"])
    check(head.rc == 0, f"cat HEAD: {head}")


# ============================================================ policy-advisor

class AdvisorWorkspace(Workspace):
    """A workspace with Bromure's OpenShell advisor on (`policy.local`
    answers only when `openShellAdvisorMode` is not "off"; the modes are
    off / review / auto, OpenShellAdvisorMode). Strict sandbox is on so
    `binaries` are enforced for policies without a `process` section, as they
    always are in an OpenShell sandbox."""

    def __init__(self, name: str):
        super().__init__(name)
        self.mode = "off"

    def ensure_advisor(self, policy: str, mode: str) -> None:
        doc = control("GET", f"/profiles/{self._quoted()}?full=1")
        doc = doc.get("profile", doc)
        if not doc.get("name"):
            r = control("POST", "/profiles", {"name": self.name, "tool": "claude", "authMode": "subscription",
                                              "networkPolicy": policy, "kernelSentry": "off",
                                              "openShellAdvisorMode": mode, "strictSandbox": True,
                                              "watchdogMode": "alert"})
            if not r.get("name"):
                raise RuntimeError(f"create {self.name}: {r}")
        elif doc.get("openShellAdvisorMode", "off") != mode or not doc.get("strictSandbox"):
            restart = not doc.get("strictSandbox")
            doc["openShellAdvisorMode"] = mode
            doc["strictSandbox"] = True
            r = control("PUT", f"/profiles/{self._quoted()}", doc)
            if r.get("ok") is False:
                raise RuntimeError(f"advisor mode rejected: {r.get('error')}")
            if restart and self.running():
                self.stop()
                self.sections = None
        self.mode = mode
        self.ensure(policy)     # policy (live) + start
        time.sleep(1.0)         # let the mode reach the proxy's cache

    def runner(self, *args: str, timeout: int = 90) -> tuple[int, object, Result]:
        """sandbox-runner.sh <cmd> <args>: returns (HTTP status, parsed body, raw)."""
        r = self.exec(["bash", "-c", fx("py_policy_advisor_sandbox_runner.sh"), "runner", *args], timeout=timeout)
        lines = r.out.splitlines()
        idx = next((i for i, l in enumerate(lines) if l.startswith("HTTP_STATUS=")), None)
        if idx is None:
            return 0, None, r
        value = lines[idx].split("=", 1)[1].strip()
        status = int(value) if value.isdigit() else 0
        text = "\n".join(lines[idx + 1:]).strip()
        try:
            body: object = json.loads(text)
        except ValueError:
            body = text
        return status, body, r


ADV = AdvisorWorkspace("E2E OpenShell Advisor")
CHUNK_KEYS = ("chunk_id", "status", "rule_name", "binary", "rejection_reason", "validation_result",
              "application_error")


def _field(body: object, key: str):
    return body.get(key) if isinstance(body, dict) else None


@pycase("policy-advisor/test.sh::agent_proposal_approve_hot_reload_github_write", f"{UPSTREAM_ADVISOR}/test.sh",
        partial="host approval (`openshell rule approve-all`) replaced by the host adding the proposed rule "
                "through a live policy update (Bromure approves in its UI; the control socket has no "
                "approve route); the GitHub write is not performed — no provider/token, so the retried PUT "
                "is only required to get past the policy (GitHub's own answer, e.g. 401)")
def advisor_github_write():
    owner = os.environ.get("DEMO_GITHUB_OWNER", "bromure-e2e")
    repo = os.environ.get("DEMO_GITHUB_REPO", "policy-advisor-demo")
    branch = os.environ.get("DEMO_BRANCH", "main")
    run_id = os.environ.get("DEMO_RUN_ID", time.strftime("%Y%m%d-%H%M%S"))
    file_path = os.environ.get("DEMO_FILE_PATH", f"openshell-policy-advisor-validation/{run_id}.md")
    policy = policy_fx("py_policy_advisor_test_policy.yaml")
    # Upstream precondition agent_policy_proposals_enabled=true ≈ advisor mode
    # "review" (proposals accepted, each waits for the user).
    ADV.ensure_advisor(policy, "review")

    # 1. check-skill: Bromure serves the advisor guide at policy.local/v1/guide
    #    instead of /etc/openshell/skills/policy_advisor.md in the image.
    status, body, raw = ADV.runner("check-skill")
    check(raw.rc == 0 and status == 200, f"check-skill: {raw}")

    # 2. current-policy → 200 (Bromure answers the YAML itself, not the
    #    {"format","policy_yaml"} envelope; upstream only asserts the status).
    status, body, raw = ADV.runner("current-policy")
    check(status == 200, f"current-policy: {raw}")

    # 3. put-file → 403 policy_denied, layer l7 / protocol rest / method PUT.
    status, body, raw = ADV.runner("put-file", owner, repo, branch, file_path, run_id)
    check(status == 403, f"put-file: expected 403, {raw}")
    check(_field(body, "error") == "policy_denied", f"deny body: {raw}")
    check(_field(body, "layer") == "l7" and _field(body, "protocol") == "rest" and _field(body, "method") == "PUT",
          f"deny body: {raw}")
    check(_field(body, "host") == "api.github.com" and _field(body, "port") == 443, f"deny body: {raw}")
    check(str(_field(body, "path") or "").endswith(file_path), f"deny body path: {raw}")
    check((_field(body, "rule_missing") or {}).get("type") == "rest_allow", f"rule_missing: {raw}")
    actions = [s.get("action") for s in (_field(body, "next_steps") or [])]
    check(actions == ["read_skill", "inspect_policy", "inspect_recent_denials", "submit_proposal"],
          f"next_steps (advisor on): {actions}")
    check(bool(_field(body, "agent_guidance")), f"agent_guidance missing: {raw}")
    note(f"deny: {_field(body, 'method')} {_field(body, 'path')} {' -> '.join(actions)}")

    # 4. submit-proposal → 202, accepted_chunks != 0.
    status, body, raw = ADV.runner("submit-proposal", owner, repo, file_path)
    check(status == 202, f"submit-proposal: expected 202, {raw}")
    check(_field(body, "status") == "submitted", f"proposal response: {raw}")
    check((_field(body, "accepted_chunks") or 0) != 0, f"no accepted chunks: {raw}")
    ids = _field(body, "accepted_chunk_ids") or []
    check(bool(ids), f"accepted_chunk_ids empty: {raw}")
    status, chunk, raw = ADV.runner("proposal-status", ids[0])
    check(status == 200 and all(k in (chunk or {}) for k in CHUNK_KEYS), f"chunk state: {raw}")
    check(_field(chunk, "status") == "pending" and _field(chunk, "rule_name") == "github_api_demo_contents_write",
          f"chunk state: {raw}")

    # 5. Host approval → Bromure: the host appends the proposed rule to the
    #    workspace policy (what an approval does) as a live update.
    approved = policy.rstrip("\n") + "\n" + "\n".join(
        "  " + l if l else l for l in textwrap.dedent(f"""\
        github_api_demo_contents_write:
          name: github_api_demo_contents_write
          endpoints:
            - host: api.github.com
              port: 443
              protocol: rest
              enforcement: enforce
              rules:
                - allow: {{method: PUT, path: "/repos/{owner}/{repo}/contents/{file_path}"}}
          binaries:
            - path: /usr/bin/curl
        """).splitlines()) + "\n"
    ADV.set_policy(approved)

    # 6. Retry up to 30 × 2 s until the PUT is no longer policy_denied.
    for _ in range(30):
        status, body, raw = ADV.runner("put-file", owner, repo, branch, file_path, run_id)
        if _field(body, "error") != "policy_denied":
            break
        time.sleep(2)
    else:
        raise AssertionError("timed out waiting for approved policy to load into the sandbox")
    # Upstream requires 200/201 (a real write with the provider's token); here
    # any answer from GitHub itself shows the request passed the policy.
    check(status != 0, f"retry never reached GitHub: {raw}")
    note(f"after live rule: PUT → {status} from GitHub")


@pycase("policy-advisor/existing-endpoint-auto-approve.sh::existing_endpoint_binary_expansion_keeps_l7",
        f"{UPSTREAM_ADVISOR}/existing-endpoint-auto-approve.sh",
        partial="the auto-approved mechanistic proposal is replaced by the host adding /usr/bin/curl to the "
                "existing rule as a live update: Bromure's mechanistic drafts are separate host:port L4 rules, "
                "not binary expansions of the existing rule, and its `rule get`/prover output has no equivalent; "
                "checked: curl denied, policy keeps rest/read-only + both binaries, curl then succeeds without "
                "restart, and (extension) a POST is still denied")
def advisor_existing_endpoint():
    policy = fx("py_existing_endpoint_auto_approve_policy.yaml")
    # "review", not "auto": in auto mode Bromure would auto-approve its own
    # L4 draft for index.crates.io:443 and race the host update below.
    ADV.ensure_advisor(policy, "review")
    url = "https://index.crates.io/config.json"

    # 1. curl (not an allowed binary) must fail.
    r = ADV.exec(["/usr/bin/curl", "-fsS", "--max-time", "10", url], timeout=30)
    check(r.rc != 0, f"curl should be denied before the binary is added: {r}")

    # 2. (Bromure) host adds /usr/bin/curl to cargo_registry's binaries, live.
    expanded = policy.rstrip("\n") + "\n      - path: /usr/bin/curl\n"
    ADV.set_policy(expanded)

    # 3. policy get --full ≈ policy.local /v1/policy/current.
    status, body, raw = ADV.runner("current-policy")
    check(status == 200, f"current-policy: {raw}")
    text = body if isinstance(body, str) else json.dumps(body)
    for want in ("protocol: rest", "access: read-only", "/usr/bin/cargo", "/usr/bin/curl"):
        check(want in text, f"effective policy lacks {want!r}: {text[:800]}")

    # 4. Retry up to 15 × 2 s: curl succeeds without a restart.
    for _ in range(15):
        r = ADV.exec(["/usr/bin/curl", "-fsS", "--max-time", "15", url], timeout=40)
        if r.rc == 0:
            break
        time.sleep(2)
    else:
        raise AssertionError(f"approved policy did not hot-reload for curl: {r}")

    # Extension (spec): read-only preserved — a POST is still an L7 deny.
    r = ADV.sh(f"curl -sS -o /tmp/post-body -w '%{{http_code}}' --max-time 15 -X POST -d x {url}; "
               "echo; cat /tmp/post-body", timeout=40)
    lines = r.out.splitlines()
    check(bool(lines) and lines[0].strip() == "403" and "policy_denied" in r.out,
          f"POST should stay denied (access: read-only): {r}")


@pycase("policy-advisor/wait-smoke.sh::proposal_wait_approved[alpha]", f"{UPSTREAM_ADVISOR}/wait-smoke.sh",
        partial="`openshell rule approve --chunk-id` replaced by the workspace's automatic approval "
                "(advisor mode auto; the proposal has no risk findings), so the long-poll resolves on an "
                "approval that lands during the submit rather than 0.3 s into the wait")
def advisor_wait_approved():
    # OpenShell's default policy (no --policy): filesystem + landlock only. No
    # `network_policies: {}` — Bromure appends approved rules to a block-style
    # mapping and refuses a flow-style one.
    ADV.ensure_advisor("version: 1\n" + BASE_SANDBOX, "auto")
    status, body, raw = ADV.runner("submit-test-proposal", "alpha")
    check(status == 202, f"submit-test-proposal: expected 202, {raw}")
    ids = _field(body, "accepted_chunk_ids") or []
    check(bool(ids), f"no accepted chunk: {raw}")
    status, chunk, raw = ADV.runner("proposal-wait", ids[0], "30", timeout=120)
    check(status == 200, f"proposal-wait: {raw}")
    check(_field(chunk, "status") == "approved", f"status: {raw}")
    check(_field(chunk, "rejection_reason") == "", f"rejection_reason: {raw}")
    check(_field(chunk, "policy_reloaded") is True, f"policy_reloaded: {raw}")


@pycase("policy-advisor/wait-smoke.sh::proposal_wait_rejected[beta]", f"{UPSTREAM_ADVISOR}/wait-smoke.sh")
def advisor_wait_rejected():
    # Review mode keeps the proposal pending; the host rejects it with a reason
    # while the agent's long-poll is waiting (upstream: `openshell rule reject
    # --chunk-id <id> --reason …`; Bromure: the control socket's reject route).
    ADV.ensure_advisor("version: 1\n" + BASE_SANDBOX, "review")
    status, body, raw = ADV.runner("submit-test-proposal", "beta")
    check(status == 202, f"submit-test-proposal: expected 202, {raw}")
    ids = _field(body, "accepted_chunk_ids") or []
    check(bool(ids), f"no accepted chunk: {raw}")
    reason = "scope to docs/ paths only, not the whole repo"
    result: dict = {}

    def wait() -> None:
        result["r"] = ADV.runner("proposal-wait", ids[0], "30", timeout=120)

    waiter = threading.Thread(target=wait)
    waiter.start()
    time.sleep(1.0)
    rejected = control("POST", f"/profiles/{urllib.parse.quote(ADV.name)}/proposals/{ids[0]}/reject",
                       {"reason": reason})
    check(rejected.get("ok") is True, f"host reject: {rejected}")
    waiter.join(timeout=130)
    status, chunk, raw = result.get("r", (0, None, "no result"))
    check(status == 200, f"proposal-wait: {raw}")
    check(_field(chunk, "status") == "rejected", f"status: {raw}")
    check(_field(chunk, "rejection_reason") == reason, f"rejection_reason: {raw}")
