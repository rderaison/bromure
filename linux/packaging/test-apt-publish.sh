#!/usr/bin/env bash
# test-apt-publish.sh — tools/apt-publish.mjs against a local directory standing
# for the Space, served on 127.0.0.1, read by apt itself. Nothing leaves the
# machine: tiny fake packages, a throwaway signing key made here.
#
# Checks: a first publish (beta), promotion of the same version to stable
# (beta's package, not a new one), a second version in beta, a repeat
# refused, another signing key refused, a dry run writes nothing, the
# indexes by hash, and apt (update + candidate) for each step.
#
# Needs node, dpkg-deb, gpg, apt-get, python3. Exit 0 = PASS.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TOOL="$ROOT/tools/apt-publish.mjs"
for t in node dpkg-deb gpg apt-get apt-cache python3 curl timeout; do
    command -v "$t" >/dev/null || { echo "FAIL: $t not found"; exit 1; }
done

W=$(mktemp -d "${TMPDIR:-/tmp}/apt-test.XXXXXX")
SERVER=""
cleanup() {
    [ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null || true
    rm -rf "$W"
}
trap cleanup EXIT

fails=0
pass() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }

# --- a throwaway signing key (and a second one, for the refusal) -------------
mkkey() {
    local home="$W/gpg-$1"
    mkdir -m 700 "$home"
    timeout 60 gpg --homedir "$home" --batch --passphrase '' --quick-gen-key "Test $1 <test@invalid>" ed25519 sign never 2>/dev/null
    gpg --homedir "$home" --batch --armor --export-secret-keys > "$W/key-$1.asc"
}
mkkey a
mkkey b

# --- fake packages ------------------------------------------------------------
mkdeb() {   # version arch
    local d="$W/pkg-$1-$2"
    mkdir -p "$d/DEBIAN" "$d/usr/share/doc/bromure-ac"
    echo "$1 $2" > "$d/usr/share/doc/bromure-ac/version"
    cat > "$d/DEBIAN/control" <<EOF
Package: bromure-ac
Version: $1
Architecture: $2
Maintainer: Test <test@invalid>
Description: test package
 A fake bromure-ac for the APT publish test.
EOF
    dpkg-deb --root-owner-group --build "$d" "$W/bromure-ac-$1_$2.deb" >/dev/null
    echo "$W/bromure-ac-$1_$2.deb"
}
A10=$(mkdeb 1.0 amd64); R10=$(mkdeb 1.0 arm64)
A11=$(mkdeb 1.1 amd64); R11=$(mkdeb 1.1 arm64)
mkdeb 1.0 i386 >/dev/null

BUCKET="$W/bucket"
mkdir -p "$BUCKET"
pub() { APT_SIGNING_KEY_FILE="$W/key-${KEY:-a}.asc" timeout 120 node "$TOOL" publish --local "$BUCKET" "$@"; }

# --- serve the bucket -----------------------------------------------------------
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
python3 -m http.server --bind 127.0.0.1 --directory "$BUCKET" "$PORT" >"$W/http.log" 2>&1 &
SERVER=$!
for _ in $(seq 50); do curl -fs -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done
URL="http://127.0.0.1:$PORT/apt"
check() { timeout 120 node "$TOOL" verify --url "$URL" "$@" >"$W/verify.log" 2>&1; }

echo "== publish 1.0 to beta"
pub --suite beta "$A10" "$R10" >"$W/p1.log" 2>&1 && pass "published" || { fail "publish"; cat "$W/p1.log"; }
check --suite beta --expect 1.0 && pass "apt sees 1.0 in beta (both arches)" || { fail "verify beta 1.0"; cat "$W/verify.log"; }
[ -f "$BUCKET/apt/pool/main/b/bromure-ac/bromure-ac_1.0_amd64.deb" ] && pass "pool layout" || fail "pool layout"
[ -f "$BUCKET/apt/bromure-archive-keyring.gpg" ] && [ -f "$BUCKET/apt/bromure-archive-keyring.asc" ] && pass "keyring published" || fail "keyring"
grep -q '^Acquire-By-Hash: yes' "$BUCKET/apt/dists/beta/Release" && pass "Acquire-By-Hash" || fail "Acquire-By-Hash"
h=$(sha256sum "$BUCKET/apt/dists/beta/main/binary-amd64/Packages.gz" | cut -d' ' -f1)
cmp -s "$BUCKET/apt/dists/beta/main/binary-amd64/Packages.gz" "$BUCKET/apt/dists/beta/main/binary-amd64/by-hash/SHA256/$h" \
    && pass "by-hash copy" || fail "by-hash copy"
# A by-hash-only fetch: apt must not need the plain names. (Served from by-hash
# since Acquire-By-Hash; hide the plain Packages and it still updates.)
mv "$BUCKET/apt/dists/beta/main/binary-amd64/Packages.gz" "$W/hidden.gz"
mv "$BUCKET/apt/dists/beta/main/binary-amd64/Packages" "$W/hidden"
check --suite beta --expect 1.0 && pass "apt reads the indexes by hash" || { fail "by-hash fetch"; cat "$W/verify.log"; }
mv "$W/hidden.gz" "$BUCKET/apt/dists/beta/main/binary-amd64/Packages.gz"
mv "$W/hidden" "$BUCKET/apt/dists/beta/main/binary-amd64/Packages"
gpg --homedir "$W/gpg-a" --batch --verify "$BUCKET/apt/dists/beta/InRelease" 2>/dev/null && pass "InRelease signed" || fail "InRelease signature"
if check --suite stable; then fail "stable verified before anything was published to it"; else pass "stable not there yet"; fi

echo "== promote 1.0 to stable (a different build of 1.0)"
# A rebuilt 1.0 (different bytes): stable gets beta's.
echo rebuilt >> "$W/pkg-1.0-amd64/usr/share/doc/bromure-ac/version"
dpkg-deb --root-owner-group --build "$W/pkg-1.0-amd64" "$W/rebuilt-1.0_amd64.deb" >/dev/null
before=$(sha256sum "$BUCKET/apt/pool/main/b/bromure-ac/bromure-ac_1.0_amd64.deb")
pub --suite stable "$W/rebuilt-1.0_amd64.deb" "$R10" >"$W/p2.log" 2>&1 && pass "promoted" || { fail "promote"; cat "$W/p2.log"; }
grep -q "stable gets that one" "$W/p2.log" && pass "said it reused beta's package" || fail "promotion message"
[ "$before" = "$(sha256sum "$BUCKET/apt/pool/main/b/bromure-ac/bromure-ac_1.0_amd64.deb")" ] \
    && pass "pool file untouched" || fail "pool file was replaced"
check --suite stable --expect 1.0 && pass "apt sees 1.0 in stable" || { fail "verify stable 1.0"; cat "$W/verify.log"; }

echo "== 1.1 to beta, amd64 only"
pub --suite beta "$A11" >"$W/p3.log" 2>&1 && pass "published" || { fail "publish 1.1"; cat "$W/p3.log"; }
check --suite beta --expect 1.1 --arches amd64 && pass "beta amd64 → 1.1" || { fail "verify beta 1.1"; cat "$W/verify.log"; }
grep -q "arm64: candidate 1.0" "$W/verify.log" && pass "beta arm64 still 1.0" || { fail "beta arm64"; cat "$W/verify.log"; }
check --suite stable --expect 1.0 && pass "stable unchanged" || { fail "stable changed"; cat "$W/verify.log"; }
n=$(grep -c '^Package: ' "$BUCKET/apt/dists/beta/main/binary-amd64/Packages")
[ "$n" = 2 ] && pass "beta amd64 keeps both versions" || fail "beta amd64 has $n entries"

echo "== refusals"
pub --suite beta "$A11" >"$W/p4.log" 2>&1 && fail "republishing 1.1 to beta was accepted" \
    || { grep -q "already in beta" "$W/p4.log" && pass "same version refused" || { fail "wrong refusal"; cat "$W/p4.log"; }; }
KEY=b pub --suite beta "$R11" >"$W/p5.log" 2>&1 && fail "another signing key was accepted" \
    || { grep -q "not the signing key" "$W/p5.log" && pass "other signing key refused" || { fail "wrong refusal"; cat "$W/p5.log"; }; }
pub --suite beta "$W/bromure-ac-1.0_i386.deb" >"$W/p6.log" 2>&1 && fail "i386 accepted" \
    || { grep -q "isn't one of" "$W/p6.log" && pass "unknown architecture refused" || { fail "wrong refusal"; cat "$W/p6.log"; }; }
APT_SIGNING_KEY= APT_SIGNING_KEY_FILE= timeout 60 node "$TOOL" publish --local "$BUCKET" --suite beta "$R11" >"$W/p7.log" 2>&1 \
    && fail "no key accepted" || pass "no signing key refused"
snap=$(cd "$BUCKET" && find . -type f -exec sha256sum {} + | sort | sha256sum)
pub --suite beta --dry-run "$R11" >"$W/p8.log" 2>&1 && pass "dry run ran" || { fail "dry run"; cat "$W/p8.log"; }
[ "$snap" = "$(cd "$BUCKET" && find . -type f -exec sha256sum {} + | sort | sha256sum)" ] \
    && pass "dry run wrote nothing" || fail "dry run changed the bucket"
grep -q "pool/main/b/bromure-ac/bromure-ac_1.1_arm64.deb" "$W/p8.log" && pass "dry run lists the upload" || fail "dry run list"

echo "== a tampered index is caught"
printf '\n' >> "$BUCKET/apt/dists/stable/main/binary-arm64/Packages"
gz="$BUCKET/apt/dists/stable/main/binary-arm64/Packages.gz"
for f in "$BUCKET"/apt/dists/stable/main/binary-arm64/by-hash/SHA256/*; do printf 'x' >> "$f"; done
printf 'x' >> "$gz"
if check --suite stable; then fail "tampered index verified"; else
    grep -qi "hash sum mismatch\|File has unexpected size\|failed" "$W/verify.log" && pass "tampered index rejected" || { fail "rejected for another reason"; cat "$W/verify.log"; }
fi
echo "== a tampered package is caught"
check --suite beta --expect 1.1 --arches amd64 && pass "beta still verifies" || { fail "beta"; cat "$W/verify.log"; }
grep -q "amd64: bromure-ac 1.1 downloads" "$W/verify.log" && pass "the package downloads" || fail "no download check"
printf 'x' >> "$BUCKET/apt/pool/main/b/bromure-ac/bromure-ac_1.1_amd64.deb"
if check --suite beta; then fail "tampered package verified"; else
    grep -q "didn't download" "$W/verify.log" && pass "tampered package rejected" || { fail "rejected for another reason"; cat "$W/verify.log"; }
fi

echo
if [ "$fails" = 0 ]; then echo "PASS"; else echo "FAIL ($fails)"; exit 1; fi
