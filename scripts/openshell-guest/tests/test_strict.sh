#!/usr/bin/env bash
# The strict sandbox's revocation must leave NOTHING on disk.
#
# This test exists because it did. The original revocation edited the root
# filesystem -- `rm /etc/sudoers.d/90-ubuntu`, write a denial, `gpasswd -d ubuntu
# docker sudo lxd adm` -- and a workspace's root disk is persistent ext4 while
# `/run` is tmpfs. So the marker vanished at reboot and the revocation did not:
#
#   * the SECOND boot of any strict workspace found sudo already gone, could not
#     run the root script that needs it, exited 75, and restart-looped forever
#     with the host seeing neither vsock 5800 nor 5840;
#   * and turning the strict sandbox OFF never gave the user back sudo or docker,
#     because nothing undid the edits.
#
# A mount namespace is the honest way to test this without wrecking the machine
# running the test: `unshare -m` gives the revocation its own view of the mount
# table, and leaving the namespace is exactly what a reboot does to a bind mount.
# So "boot", "reboot" and "boot again" are three namespaces over one /etc.
#
# Run: tests/test_strict.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
STRICT="$ROOT/bromure-strict.py"
WORK=$(mktemp -d /tmp/stricttest-XXXXXX)
fails=0

say() { printf '\n=== %s ===\n' "$1"; }
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

cleanup() { sudo rm -rf "$WORK"; }
trap cleanup EXIT

USER_NAME=$(id -un)

# --------------------------------------------------------------------------
say "1. the rewriting itself"
python3 - <<PY
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bs", "$STRICT")
bs = importlib.util.module_from_spec(spec); spec.loader.exec_module(bs)
cases = [
    ("docker:x:103:$USER_NAME\n",        "docker:x:103:\n"),
    ("sudo:x:27:$USER_NAME,alice\n",     "sudo:x:27:alice\n"),
    ("adm:x:4:syslog,$USER_NAME,bob\n",  "adm:x:4:syslog,bob\n"),
    ("video:x:44:$USER_NAME\n",          "video:x:44:$USER_NAME\n"),
    ("root:x:0:\n",                      "root:x:0:\n"),
    ("# comment\n",                      "# comment\n"),
    ("malformed\n",                      "malformed\n"),
]
bad = 0
for src, want in cases:
    got = bs.rewrite_group_line(src, "$USER_NAME", bs.PRIVILEGED_GROUPS)
    if got != want:
        print("  FAIL %r -> %r, wanted %r" % (src, got, want)); bad += 1
print("  ok   %d group-line rewrites, including comments and malformed lines"
      % len(cases)) if not bad else None
sys.exit(1 if bad else 0)
PY
[ $? -eq 0 ] || fails=$((fails + 1))

# --------------------------------------------------------------------------
say "2. a strict boot leaves /etc byte-identical"
# The baseline is taken here, OUTSIDE any namespace, so it is the real inodes.
# As root: /etc/gshadow is 0640 root:shadow, and a baseline that cannot read it
# would compare "unreadable" with "unreadable" and never notice a change there.
BASE=$(sudo python3 "$STRICT" baseline)
[ -n "$BASE" ] || { echo "  FAIL could not take a baseline"; exit 1; }
echo "$BASE" > "$WORK/baseline.json"

# "Boot": apply inside a private mount namespace, prove the revocation is real
# in there, then leave -- which is what a reboot does to a bind mount.
sudo unshare -m --propagation private /bin/sh -c "
    python3 '$STRICT' apply > '$WORK/apply1.json' 2>'$WORK/apply1.err'
    # Inside: is the user actually out of the privileged groups?
    grep -E '^(docker|sudo|adm|lxd):' /etc/group > '$WORK/groups-inside.txt'
    ls /etc/sudoers.d > '$WORK/sudoers-inside.txt'
    # And does the REAL sudo honour it?
    setpriv --reuid=$(id -u) --regid=$(id -g) --clear-groups \
        sudo -n true 2>'$WORK/sudo-inside.err'
    echo \$? > '$WORK/sudo-inside.rc'
" 2>/dev/null
sudo chown -R "$(id -u):$(id -g)" "$WORK" 2>/dev/null

if grep -q '"ok": true' "$WORK/apply1.json" 2>/dev/null; then
    ok "the revocation applied"
else
    bad "the revocation did not apply: $(cat "$WORK/apply1.err" 2>/dev/null | head -2)"
fi
if grep -qE "^(docker|sudo|adm|lxd):.*\b$USER_NAME\b" "$WORK/groups-inside.txt" 2>/dev/null; then
    bad "the user is still in a privileged group inside the namespace"
else
    ok "inside, the user is out of docker/sudo/adm/lxd"
fi
if grep -q "zz-bromure-strict" "$WORK/sudoers-inside.txt" 2>/dev/null \
   && ! grep -q "90-ubuntu" "$WORK/sudoers-inside.txt" 2>/dev/null; then
    ok "inside, the NOPASSWD drop-in is gone and the denial is present"
else
    bad "sudoers.d inside is wrong: $(tr '\n' ' ' < "$WORK/sudoers-inside.txt")"
fi
check "inside, real sudo refuses" "$(cat "$WORK/sudo-inside.rc" 2>/dev/null)" "1"

# "Reboot": the namespace is gone. Nothing may have changed on disk.
AFTER=$(sudo python3 "$STRICT" verify "$BASE" 2>&1)
if echo "$AFTER" | grep -q '"ok": true'; then
    ok "after the namespace exits, /etc/group, /etc/gshadow and /etc/sudoers.d are byte-identical"
else
    bad "the revocation left something on disk: $AFTER"
fi
check "sudo works again outside" \
    "$(sudo -n true 2>/dev/null && echo yes || echo no)" "yes"
check "the user is back in the docker group" \
    "$(id -nG | tr ' ' '\n' | grep -cx docker)" "1"

# --------------------------------------------------------------------------
say "3. the SECOND boot of the same root still works"
# This is the exact failure: boot 1 revoked persistently, boot 2 had no sudo to
# apply anything with, and agentd restart-looped forever. With a runtime-only
# revocation, boot 2 is identical to boot 1.
sudo unshare -m --propagation private /bin/sh -c "
    python3 '$STRICT' apply > '$WORK/apply2.json' 2>&1
    grep -E '^(docker|sudo):' /etc/group > '$WORK/groups2.txt'
" 2>/dev/null
sudo chown -R "$(id -u):$(id -g)" "$WORK" 2>/dev/null
if grep -q '"ok": true' "$WORK/apply2.json" 2>/dev/null; then
    ok "the second boot applies the revocation exactly as the first did"
else
    bad "the second boot could not apply it: $(head -2 "$WORK/apply2.json")"
fi
if grep -qE "^(docker|sudo):.*\b$USER_NAME\b" "$WORK/groups2.txt" 2>/dev/null; then
    bad "the second boot did not remove the user from the groups"
else
    ok "and the user is out of the groups again"
fi

# --------------------------------------------------------------------------
say "3b. the result is published, and a failure cannot look like success"
# A revocation that failed but was reported as applied is worse than one that
# never ran: the host would treat the workspace as strict while the agent still
# holds sudo.
sudo unshare -m --propagation private /bin/sh -c "
    BROMURE_STRICT_RESULT='$WORK/strict-result.json' python3 '$STRICT' apply \
        > /dev/null 2>&1
" 2>/dev/null
sudo chown "$(id -u)" "$WORK/strict-result.json" 2>/dev/null
check "a successful apply publishes applied=true" \
    "$(python3 -c "
import json;print(json.load(open('$WORK/strict-result.json'))['applied'])" 2>/dev/null)" \
    "True"

# Now make it fail: point it at a group file it cannot rewrite safely.
mkdir -p "$WORK/badetc/sudoers.d"
printf 'docker:x:103:%s\n' "$USER_NAME" > "$WORK/badetc/group"   # no root line
sudo unshare -m --propagation private /bin/sh -c "
    BROMURE_STRICT_RESULT='$WORK/bad-result.json' \
    BROMURE_GROUP_FILE='$WORK/badetc/group' \
    BROMURE_GSHADOW_FILE='$WORK/badetc/gshadow' \
    BROMURE_SUDOERS_D='$WORK/badetc/sudoers.d' \
    BROMURE_STRICT_RUN='$WORK/badrun' python3 '$STRICT' apply > /dev/null 2>&1
" 2>/dev/null
sudo chown "$(id -u)" "$WORK/bad-result.json" 2>/dev/null
check "a rewrite that would lose root is refused and reported" \
    "$(python3 -c "
import json;d=json.load(open('$WORK/bad-result.json'));print(d['applied'])" 2>/dev/null)" \
    "False"
if python3 -c "
import json,sys
d=json.load(open('$WORK/bad-result.json'))
sys.exit(0 if any('lost root' in p for p in d['problems']) else 1)" 2>/dev/null; then
    ok "and the reason names what was wrong"
else
    bad "the failure carries no usable reason"
fi
check "sandbox_status surfaces it" \
    "$(python3 -c "
import sys; sys.path.insert(0,'$ROOT')
import bromure_sandbox_status as s
st = s.build('/nonexistent','/nonexistent','$WORK/bad-result.json')
print(st['strict_applied'])")" "False"

# --------------------------------------------------------------------------
say "4. turning strict OFF gives the privileges back"
# The other half of the persistence bug: a user who switched strict off never got
# sudo or docker back, because nothing undid the disk edits. With nothing written
# to disk there is nothing to undo -- a boot that does not apply the revocation
# simply has it.
check "sudo works" "$(sudo -n true 2>/dev/null && echo yes || echo no)" "yes"
check "docker group" "$(id -nG | tr ' ' '\n' | grep -cx docker)" "1"
FINAL=$(sudo python3 "$STRICT" verify "$BASE" 2>&1)
if echo "$FINAL" | grep -q '"ok": true'; then
    ok "and /etc is still exactly as it was before any of this ran"
else
    bad "/etc drifted across three boots: $FINAL"
fi

printf '\n%s\n' "$([ "$fails" -eq 0 ] && echo "ALL STRICT TESTS PASSED" || echo "$fails CHECK(S) FAILED")"
exit $((fails > 0))
