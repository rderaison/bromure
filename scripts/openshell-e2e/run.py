#!/usr/bin/env python3
"""Run the OpenShell e2e scenarios against an isolated Bromure instance.

  BROMURE_AC=<.app>/Contents/MacOS/bromure-ac CFFIXED_USER_HOME=/private/tmp/brmK \
      python3 run.py [substring ...]
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

if __name__ == "__main__":
    out = os.environ.get("E2E_RESULTS", "results.json")
    failures = bromure_e2e.run(sys.argv[1:] or None, out)
    counts = {}
    for c in bromure_e2e.CASES:
        counts[c.status] = counts.get(c.status, 0) + 1
    print("summary:", counts)
    sys.exit(1 if failures else 0)
