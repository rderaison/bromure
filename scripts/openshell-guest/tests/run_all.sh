#!/usr/bin/env bash
# Every guest-side test, in the order that keeps them runnable.
#
# test_lockdown.sh --raise is NOT included: raising lockdown is one-way for the
# boot and, once raised, no unsigned module loads, so it would break
# test_sentry.sh for every later run. Run it last, by hand, on a VM you can
# reboot.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
fails=0
skipped=""

banner() { printf '\n\n########## %s ##########\n' "$1"; }

# Run one suite and classify its status: 0 pass, 77 could-not-run, anything else
# a failure.
#
# One classifier for every suite, because having it at only SOME call sites is
# how a skip gets counted as a failure: `test_boot.sh` was changed to exit 77
# when a case cannot run, and the plain `|| fails=$((fails + 1))` here turned
# that into "1 SUITE(S) FAILED" on a run where nothing had failed. Either every
# suite's 77 means the same thing or none of them do.
run_suite() {   # run_suite <skip-note> <command...>
    local note="$1"; shift
    "$@"
    local rc=$?
    if [ "$rc" = 77 ]; then
        skipped="${skipped}${note} "
    elif [ "$rc" != 0 ]; then
        fails=$((fails + 1))
    fi
}

banner "syscall table + filter sizes"
run_suite "syscall table" python3 "$HERE/test_syscall_table.py"

banner "differential vs OpenShell's own crates"
if [ -x "$ROOT/differential/target/release/openshell-diff" ]; then
    (cd "$ROOT/differential" && ./diff.py --keep-going) || fails=$((fails + 1))
else
    # Counted as a FAILURE, and deliberately not called a skip: an unbuilt
    # differential binary is something to fix in thirty seconds, not a limit of
    # the machine. The word matters now that 77 means "could not run".
    echo "FAIL: the differential harness is not built."
    echo "      (cd differential && cargo build --release)"
    fails=$((fails + 1))
fi

banner "idmapped mounts"
run_suite "idmapped mounts" sudo python3 "$HERE/test_idmap.py"

banner "sandbox end to end"
run_suite "sandbox end to end" "$HERE/test_sandbox.sh"

banner "kernel sentry end to end"
# 77 = "the environment cannot run this", not "it failed". The suite prints why.
# It is still counted, loudly, in the summary: a skip that reads as a pass is how
# a suite stops meaning anything.
run_suite "kernel sentry (lockdown refuses unsigned modules)" \
    "$HERE/test_sentry.sh"

banner "network lineage"
# Also 77-on-skip: it loads the testable build, so lockdown stops it for the
# same one-way reason.
run_suite "network lineage (needs a fresh VM, or a tool/route was missing)" \
    "$HERE/test_net_flow.sh"

banner "strict revocation leaves nothing on disk"
run_suite "strict revocation" "$HERE/test_strict.sh"

banner "two-incarnation boot"
run_suite "a boot case (see above)" "$HERE/test_boot.sh"

banner "lockdown surfaces (probe only)"
run_suite "lockdown surfaces" "$HERE/test_lockdown.sh"

# The VERDICT carries the skip, not a line above it.
#
# "ALL SUITES PASSED" as the last line of a run where a suite never executed is
# the misleading green this project keeps finding in other people's code and had
# in its own: whoever reads only the final line would be told everything passed
# when one suite did not run at all.
if [ -n "$skipped" ]; then
    printf '\n\n!! SKIPPED, NOT RUN: %s\n' "$skipped"
    printf '   Run these on a fresh VM; lockdown is one-way until reboot.\n'
fi
if [ "$fails" -ne 0 ]; then
    verdict="$fails SUITE(S) FAILED"
elif [ -n "$skipped" ]; then
    verdict="the suites that RAN passed -- but one or more were SKIPPED (above)"
else
    verdict="ALL SUITES PASSED"
fi
printf '\n%s\n' "$verdict"
# And the EXIT STATUS carries it as well. The verdict line was already honest,
# but `exit 0` on a run where a suite never executed is the same misleading green
# one layer down: anything reading the status rather than the text -- CI, a
# wrapper script, the next pair of eyes in a hurry -- was told everything passed.
# 77 is "could not run", distinct from 0 and from 1.
if [ "$fails" -ne 0 ]; then
    exit 1
elif [ -n "$skipped" ]; then
    exit 77
fi
exit 0
