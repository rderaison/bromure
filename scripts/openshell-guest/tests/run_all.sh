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

banner "syscall table + filter sizes"
python3 "$HERE/test_syscall_table.py" || fails=$((fails + 1))

banner "differential vs OpenShell's own crates"
if [ -x "$ROOT/differential/target/release/openshell-diff" ]; then
    (cd "$ROOT/differential" && ./diff.py --keep-going) || fails=$((fails + 1))
else
    echo "SKIP: build it first -> (cd differential && cargo build --release)"
    fails=$((fails + 1))
fi

banner "idmapped mounts"
sudo python3 "$HERE/test_idmap.py" || fails=$((fails + 1))

banner "sandbox end to end"
"$HERE/test_sandbox.sh" || fails=$((fails + 1))

banner "kernel sentry end to end"
# 77 = "the environment cannot run this", not "it failed". The suite prints why.
# It is still counted, loudly, in the summary: a skip that reads as a pass is how
# a suite stops meaning anything.
"$HERE/test_sentry.sh"
sentry_rc=$?
if [ "$sentry_rc" = 77 ]; then
    skipped="${skipped}kernel sentry (lockdown refuses unsigned modules) "
elif [ "$sentry_rc" != 0 ]; then
    fails=$((fails + 1))
fi

banner "strict revocation leaves nothing on disk"
"$HERE/test_strict.sh" || fails=$((fails + 1))

banner "two-incarnation boot"
"$HERE/test_boot.sh" || fails=$((fails + 1))

banner "lockdown surfaces (probe only)"
"$HERE/test_lockdown.sh" || fails=$((fails + 1))

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
exit $((fails > 0))
