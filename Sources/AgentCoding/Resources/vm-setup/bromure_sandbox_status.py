#!/usr/bin/env python3
"""The `sandbox_status` line attestd sends the host on vsock 5840.

Split out of attestd so it can be unit-tested without a vsock, and so agentd can
read the same status for its own logging without duplicating the merge.

Two producers write into /run/bromure-sandbox: `bromure-sandboxd` writes
status.json (the Landlock/seccomp/run_as picture) and `bromure-sentryd` writes
sentry.json (the module picture). They run at different times and either can be
absent, so the merge here is deliberately total: a missing file is a defined
state, never an exception.
"""

import json
import os

RUN_DIR = "/run/bromure-sandbox"
SANDBOX_STATUS = os.path.join(RUN_DIR, "status.json")
SENTRY_STATUS = os.path.join(RUN_DIR, "sentry.json")
STRICT_STATUS = os.path.join(RUN_DIR, "strict.json")
SPEC_PATH = os.path.join(os.environ.get("BROMURE_META", "/mnt/bromure-meta"),
                         "openshell-sandbox.json")

# `pending` is the state before a producer has spoken, and it is not the same as
# `off`.
#
# attestd connects within a few seconds of boot and sends the first status
# immediately, which on a strict workspace is BEFORE the supervisor has published
# anything. Reporting `off` there is wrong twice over: it puts a misleading "no
# filesystem policy" row in the user's timeline on every boot, and if the sentry
# ever wins the race and connects on 5841 first, the host's cross-check sees
# "connected while the guest says the sentry is off" and scores it as tampering,
# weight 20. A false alarm at second four of every boot.
#
# So: a spec that asks for something whose producer has not yet answered is
# `pending`, which the host treats as unknown — no row, no cross-check.
VALID_FILESYSTEM = ("enforced", "degraded", "failed", "off", "pending")
VALID_SENTRY = ("running", "unavailable", "off", "pending")


def _read(path):
    try:
        with open(path) as handle:
            value = json.load(handle)
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def _spec(spec_path):
    """What the host ASKED for, which is how `pending` is told from `off`."""
    try:
        with open(spec_path) as handle:
            value = json.load(handle)
        return value if isinstance(value, dict) else None
    except (OSError, ValueError):
        return None


def _section(spec, name):
    """One section of the spec, always a dict.

    `spec.get("sentry", {})` is not the same thing and the difference crashes:
    a key that is PRESENT with value `null` returns `None`, not the default, so
    `.get("enabled")` on it raises `AttributeError`. `{"sentry": null}` is a
    perfectly ordinary way for a host to say "no sentry", and it would have taken
    the whole status line down -- which on this channel means the host stops
    hearing anything about the workspace. Same for a section that is a string or
    a list because something upstream changed shape.

    This file's job is to be TOTAL: every input, including a malformed one, has
    to map to a defined status rather than an exception.
    """
    if not isinstance(spec, dict):
        return {}
    value = spec.get(name)
    return value if isinstance(value, dict) else {}


def build(sandbox_path=SANDBOX_STATUS, sentry_path=SENTRY_STATUS,
          strict_path=STRICT_STATUS, spec_path=SPEC_PATH):
    """The unsolicited line, exactly in the contract's §3 shape.

    Extra keys beyond the contract — `warnings`, `sentry_digest`, `tmux_socket`
    — are additive; a host that ignores them reads the same status it would
    have. `sentry_digest` is the one the host cross-checks against the secret in
    the sentry's hello on 5841.
    """
    sandbox = _read(sandbox_path)
    sentry = _read(sentry_path)
    strict = _read(strict_path)
    spec = _spec(spec_path)

    if sandbox:
        filesystem = sandbox.get("filesystem", "off")
    elif spec is not None and spec.get("filesystem_policy") is not None:
        # A policy was asked for and the supervisor has not published yet: that
        # is `pending`, not "there is no policy". A spec that explicitly carries
        # `filesystem_policy: null` is already known to be `off`, so it does not
        # need a pending window nobody learns anything from.
        filesystem = "pending"
    else:
        filesystem = "off"
    if filesystem not in VALID_FILESYSTEM:
        filesystem = "off"
    # sentry.json is authoritative when it exists; status.json's copy is what
    # the supervisor last folded in, which covers the window before attestd
    # can see the file itself.
    sentry_state = sentry.get("sentry") or sandbox.get("sentry")
    if not sentry_state:
        wanted = bool(_section(spec, "sentry").get("enabled"))
        # Asked for and not yet answered is pending; never asked for is off.
        sentry_state = "pending" if wanted else "off"
    if sentry_state not in VALID_SENTRY:
        sentry_state = "off"

    warnings = list(sandbox.get("warnings") or [])
    # A revocation that failed must never be reported as applied: the host would
    # treat the workspace as strict while the agent still holds sudo.
    for problem in (strict.get("problems") or []):
        warnings.append("strict revocation: %s" % problem)
    if sentry.get("reason") and sentry_state != "off":
        warnings.append("sentry: %s" % sentry["reason"])

    return {
        "event": "sandbox_status",
        "landlock_abi": sandbox.get("landlock_abi"),
        "filesystem": filesystem,
        "degraded_reason": sandbox.get("degraded_reason"),
        "run_as": sandbox.get("run_as"),
        "seccomp": sandbox.get("seccomp", "off"),
        "additions": sandbox.get("additions")
        or {"read_write": [], "read_only": []},
        "sentry": sentry_state,
        # Why, when it is not running. The host distinguishes `off` ("nobody
        # asked for it") from `unavailable` ("it was asked for and could not
        # start"), and for a hard requirement it has to show the user which.
        "sentry_reason": sentry.get("reason") or sandbox.get("sentry_reason"),
        # null whenever the sentry isn't running, per the host's contract: the
        # host alarms if it has a pinned hello on 5841 but the guest reports no
        # digest here, because that is what an impostor looks like.
        "sentry_digest": ((sentry.get("digest") or sandbox.get("sentry_digest"))
                          if sentry_state == "running" else None),
        # What the host asked for, so it can tell "not yet" from "not wanted"
        # without having to infer it.
        "requested": ({"filesystem": spec.get("filesystem_policy") is not None,
                       "process": spec.get("process") is not None,
                       "strict": bool(spec.get("strict_sandbox")),
                       "sentry": bool(_section(spec, "sentry").get("enabled"))}
                      if spec is not None else None),
        "lockdown": sentry.get("lockdown"),
        # null when no revocation was attempted; false is a workspace that asked
        # for the strict sandbox and did not get it.
        "strict_applied": strict.get("applied") if strict else None,
        "warnings": warnings,
        # Which guest code this workspace is running. A blocker that looked
        # identical whether or not the fix was deployed cost a round; the host can
        # now log it and neither side has to guess.
        "build": sandbox.get("build"),
        # What the remap actually did, so "may not be able to write" never has to
        # be guessed at again: `run_as.workdirs_writable` is the measured answer.
        "idmap": sandbox.get("idmap"),
        "session_ready": sandbox.get("session_ready"),
    }


def fingerprint(status):
    """What "changed" means for the resend rule in §3.

    The contract says to send once the sandbox is in place and again on any
    change. Comparing the whole dict would resend on nothing, so this is the
    fields the host acts on.

    **`warnings` is one of them, as a set.** Leaving it out was a real bug with a
    cost: the supervisor's "here is why there is no session" diagnosis was written
    into `status.json` exactly as designed, and then never reached the host,
    because adding a warning did not change the fingerprint and attestd only
    resends on a change. The host saw a workspace that never produced a shell and
    never said why -- so the diagnostic that existed to end an ambiguity silently
    preserved it.

    A *set*, and sorted, because the original worry was real: `warnings` is built
    by appends from several threads and its order is not stable, so comparing the
    list would resend on nothing. Comparing the set resends when a warning appears
    or goes away, which is precisely the event worth a frame.

    `build` is here for the same reason in the other direction: a workspace whose
    guest code was replaced under it should say so.
    """
    return json.dumps({
        key: status.get(key)
        for key in ("filesystem", "degraded_reason", "run_as", "seccomp",
                    "sentry", "sentry_reason", "sentry_digest", "landlock_abi",
                    "lockdown", "server_pid", "server_restarts", "strict_applied",
                    "build")
    }, sort_keys=True) + json.dumps(sorted(set(status.get("warnings") or [])))


if __name__ == "__main__":
    print(json.dumps(build(), sort_keys=True, indent=2))
