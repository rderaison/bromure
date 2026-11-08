#!/usr/bin/env python3
"""The guest suites' verdict (run.sh): each suite's ok/FAIL/SKIP counts, its
unexpected FAILs, and every expected-failures.tsv entry checked against the
logs. Exit 0: every FAIL expected, with its count; 1: an unexpected FAIL, or a
suite that didn't finish; 2: an expected failure that now passes, partly or
wholly (an entry that matched nothing is STALE, also listed as a warning).
Usage: verdict.py OUT_DIR EXPECTED_TSV SUITE..."""
import os, re, sys
out, tsv, suites = sys.argv[1], sys.argv[2], sys.argv[3:]
expected = []
for line in open(tsv):
    if line.startswith("#") or not line.strip():
        continue
    suite, rx, count, why = line.rstrip("\n").split("\t")
    expected.append((suite, re.compile(rx), int(count), why))
status, unexpected_pass = 0, 0


def read_log(suite):
    """The suite's log lines, or None when it left none."""
    try:
        return open(os.path.join(out, suite + ".log"), errors="replace").read().splitlines()
    except OSError:
        return None

print("\n%-15s %4s %6s %6s %10s %6s" % ("suite", "rc", "ok", "FAIL", "unexpected", "SKIP"))
for s in suites:
    lines = read_log(s) or []
    rc = next((l.split("=", 1)[1] for l in reversed(lines) if l.startswith("SUITE_RC=")), "none")
    ok = sum(1 for l in lines if re.match(r"\s*ok\s", l))
    fails = [l.strip() for l in lines if re.match(r"\s*FAIL\s", l)]
    skips = sum(1 for l in lines if re.match(r"\s*SKIP\s", l))
    mine = [e for e in expected if e[0] == s]
    unexpected = [f for f in fails if not any(e[1].search(f) for e in mine)]
    print("%-15s %4s %6d %6d %10d %6d" % (s, rc, ok, len(fails), len(unexpected), skips))
    for f in unexpected:
        print("    UNEXPECTED " + f[:160])
    if unexpected or (rc not in ("0", "1", "77") ) or (rc == "1" and not fails):
        status = max(status, 1)
        if rc == "1" and not fails:
            print("    the suite exited 1 without a FAIL line")
        if rc not in ("0", "1", "77"):
            print("    the suite did not finish normally (rc %s)" % rc)
print("\nexpected failures:")
warnings = []
for suite, rx, count, why in expected:
    if suite not in suites:
        continue
    lines = read_log(suite)
    if lines is None:
        # The suite never ran (or left no log): its entries say nothing, and
        # the missing suite already fails the run above.
        verdict = "not checked (the suite left no log)"
    else:
        seen = sum(1 for l in lines if rx.search(l.strip()) or rx.search(l))
        if seen == count:
            verdict = "expected (%d)" % seen
        elif seen == 0:
            # Stale: the failure is gone, or its message changed. CI catches
            # it (exit 2, as a partial pass): the table no longer describes
            # what the suites do.
            verdict = "STALE: matched nothing in this run -- update expected-failures.tsv"
            warnings.append("%s: %s" % (suite, rx.pattern))
            unexpected_pass = 1
        elif seen < count:
            verdict = "UNEXPECTED PASS: %d of %d still fail -- update expected-failures.tsv" % (seen, count)
            unexpected_pass = 1
        else:
            verdict = "seen %d times, expected %d" % (seen, count)
            status = max(status, 1)
    print("  %-14s %-58s %s" % (suite, rx.pattern[:58], verdict))
    print("  %-14s %s" % ("", why[:110]))
if warnings:
    print("\nwarning: %d stale expected-failures.tsv entr%s (matched nothing):" % (len(warnings), "y" if len(warnings) == 1 else "ies"))
    for w in warnings:
        print("  " + w)
sys.exit(status if status else (2 if unexpected_pass else 0))
