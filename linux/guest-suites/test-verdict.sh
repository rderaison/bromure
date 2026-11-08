#!/usr/bin/env bash
# verdict.py on fixture logs (no VM): every expected failure seen -> 0; an entry
# that matched nothing -> STALE, warned, 2; a partial pass -> 2; an unexpected
# FAIL -> 1; a suite that left no log -> its entries "not checked", 1.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1   # no __pycache__ beside verdict.py
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d /tmp/acl-verdict.XXXXXX)
trap 'rm -rf -- "$T"' EXIT
fails=0
check() {  # name, want-rc, want-text, suites...
  local name=$1 want=$2 text=$3; shift 3
  out=$(python3 -I "$HERE/verdict.py" "$T" "$T/tsv" "$@" 2>&1); rc=$?
  if [ "$rc" = "$want" ] && grep -q -- "$text" <<<"$out"; then echo "PASS $name"
  else echo "FAIL $name (rc $rc, want $want; wanted '$text')"; echo "$out" | sed 's/^/    /'; fails=$((fails + 1)); fi
}
printf 'suiteA\tknown bug\t1\tdocumented\n' > "$T/tsv"
printf '  ok one\n  FAIL known bug here\nSUITE_RC=1\n' > "$T/suiteA.log"
check "all expected" 0 "expected (1)" suiteA
printf '  ok one\n  ok two\nSUITE_RC=0\n' > "$T/suiteA.log"
check "stale entry" 2 "STALE: matched nothing" suiteA
check "stale warning" 2 "warning: 1 stale expected-failures.tsv entry" suiteA
printf 'suiteA\tknown bug\t2\tdocumented\n' > "$T/tsv"
printf '  FAIL known bug here\nSUITE_RC=1\n' > "$T/suiteA.log"
check "partial pass" 2 "UNEXPECTED PASS: 1 of 2" suiteA
printf '  FAIL known bug here\n  FAIL something new\nSUITE_RC=1\n' > "$T/suiteA.log"
check "unexpected FAIL" 1 "UNEXPECTED FAIL something new" suiteA
rm -f -- "$T/suiteA.log"
check "no log" 1 "not checked (the suite left no log)" suiteA
[ "$fails" = 0 ] && { echo "verdict: all PASS"; exit 0; }
echo "verdict: $fails FAIL"; exit 1
