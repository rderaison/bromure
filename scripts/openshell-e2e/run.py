#!/usr/bin/env python3
"""Run the OpenShell e2e scenarios against an isolated Bromure instance.

  BROMURE_AC=<.app>/Contents/MacOS/bromure-ac CFFIXED_USER_HOME=/private/tmp/brmK \
      python3 run.py [--known-ok] [substring ...]

--known-ok: the divergences RESULTS.md documents (KNOWN_FAILURES) don't fail
the run; any other failure does. What CI runs.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bromure_e2e  # noqa: E402
import scenarios_rust_a  # noqa: E402,F401

for extra in ("scenarios_rust_b", "scenarios_python"):
    try:
        __import__(extra)
    except ModuleNotFoundError:
        pass

# Known divergences from OpenShell, argued in RESULTS.md: they fail here by
# design or by a documented gap. CI (`--known-ok`) fails only on the others,
# and says so when one of these starts passing (take it off the list).
KNOWN_FAILURES = {
    "bypass_detection::bypass_attempt_is_rejected_fast",
    "proxy_egress_pipeline::transparent_pipeline_never_reaches_upstream_as_first_request_overflow",
    "proxy_egress_pipeline::chunked_pipeline_is_authorized_separately_before_reaching_upstream",
    "test_sandbox_policy::test_transparent_tcp_policy_denies_unauthorized_connections[no-policy]",
    "test_sandbox_policy::test_transparent_tcp_policy_denies_unauthorized_connections[wrong-port]",
    "test_sandbox_policy::test_transparent_tcp_policy_denies_unauthorized_connections[wrong-binary]",
}


def verdict(cases, known_ok):
    """(exit code, report lines) for a finished run."""
    ran = [c for c in cases if c.status != "pending"]
    failed = [c for c in ran if c.status in ("fail", "error")]
    if not known_ok:
        return (1 if failed else 0), []
    unexpected = [c for c in failed if c.id not in KNOWN_FAILURES]
    fixed = [c for c in ran if c.id in KNOWN_FAILURES and c.status == "pass"]
    lines = ["known divergence: %s" % c.id for c in failed if c.id in KNOWN_FAILURES]
    lines += ["UNEXPECTED %s: %s" % (c.status, c.id) for c in unexpected]
    lines += ["known divergence now passes (drop it from KNOWN_FAILURES): %s" % c.id for c in fixed]
    return (1 if unexpected else 0), lines


if __name__ == "__main__":
    args = sys.argv[1:]
    known_ok = "--known-ok" in args
    args = [a for a in args if a != "--known-ok"]
    out = os.environ.get("E2E_RESULTS", "results.json")
    bromure_e2e.run(args or None, out)
    counts = {}
    for c in bromure_e2e.CASES:
        counts[c.status] = counts.get(c.status, 0) + 1
    print("summary:", counts)
    code, lines = verdict(bromure_e2e.CASES, known_ok)
    for line in lines:
        print(line)
    sys.exit(code)
