#!/usr/bin/env bash
# Build the sentry module for every Ubuntu kernel that doesn't have one yet.
# Runs inside the container from ./Dockerfile (ubuntu:24.04, arm64), started by
# Jenkinsfile.sentry; results are copied out of /out with `docker cp`.
#
#   1. Hash the source (./source-hash.sh): modules are published per source.
#   2. Fetch the published catalog for that hash, if any: its kernels are done.
#   3. List the kernel ABIs the archive offers (linux-headers-<ABI>-generic
#      matching KERNEL_PATTERN), newest first, and build each missing one with
#      ./build.sh --verify (two builds must agree byte for byte).
#   4. Write /out/manifest.json: what was built, what failed, and the source.
#
# Env:
#   PUBLIC_BASE        CDN base (default https://dl.bromure.io)
#   KERNEL_PATTERN     ERE over header package names
#                      (default ^linux-headers-6\.8\.0-[0-9]+-generic$, the
#                      noble GA kernel the base images use)
#   MAX_BUILDS         cap per run (default 12); the rest go next run
#   FORCE_KERNELS      space-separated kernels to (re)build even if published
#   SOURCE_DATE_EPOCH  from the repository (the container has no git history)
set -euo pipefail

SRC=/src
OUT=/out
PUBLIC_BASE="${PUBLIC_BASE:-https://dl.bromure.io}"
KERNEL_PATTERN="${KERNEL_PATTERN:-^linux-headers-6\.8\.0-[0-9]+-generic$}"
MAX_BUILDS="${MAX_BUILDS:-12}"
FORCE_KERNELS="${FORCE_KERNELS:-}"
: "${SOURCE_DATE_EPOCH:?set SOURCE_DATE_EPOCH from the repository}"
export SOURCE_DATE_EPOCH DEBIAN_FRONTEND=noninteractive

mkdir -p "$OUT/modules"
HASH=$(sh "$SRC/source-hash.sh" "$SRC")
echo "source hash: $HASH"

# --- 2. What's already published --------------------------------------------
PUBLISHED=""
code=$(curl -sS -o "$OUT/previous-catalog.json" -w '%{http_code}' \
            -H 'Cache-Control: no-cache' "$PUBLIC_BASE/sentry/$HASH/catalog.json") || true
code=${code:-000}
case "$code" in
    200) PUBLISHED=$(python3 -c 'import json,sys
print(" ".join(m["kernel"] for m in json.load(open(sys.argv[1])).get("modules", [])))' \
                     "$OUT/previous-catalog.json")
         echo "published for this source: ${PUBLISHED:-none}" ;;
    404|403) rm -f "$OUT/previous-catalog.json"; echo "nothing published for this source yet" ;;
    *)   echo "cannot read the published catalog (HTTP $code); refusing to guess" >&2; exit 1 ;;
esac

# --- 3. What the archive offers ----------------------------------------------
apt-get update -qq
mapfile -t CANDIDATES < <(apt-cache pkgnames linux-headers- | grep -E "$KERNEL_PATTERN" \
                           | sed 's/^linux-headers-//' | sort -rV)
echo "archive offers ${#CANDIDATES[@]} kernel(s) matching $KERNEL_PATTERN"
[ "${#CANDIDATES[@]}" -gt 0 ] || { echo "no kernels matched; check KERNEL_PATTERN" >&2; exit 1; }

TODO=()
for k in "${CANDIDATES[@]}"; do
    if [[ " $FORCE_KERNELS " == *" $k "* ]] || [[ " $PUBLISHED " != *" $k "* ]]; then
        TODO+=("$k")
    fi
done
for k in $FORCE_KERNELS; do   # a forced kernel the archive no longer lists still gets tried
    [[ " ${TODO[*]:-} " == *" $k "* ]] || TODO+=("$k")
done
echo "to build: ${TODO[*]:-nothing}"

BUILT=()
FAILED=()
for k in "${TODO[@]:0:$MAX_BUILDS}"; do
    echo
    echo "=== $k ==="
    if ! apt-get install -y -qq --no-install-recommends "linux-headers-$k" > "$OUT/apt-$k.log" 2>&1; then
        echo "headers for $k not installable"; tail -5 "$OUT/apt-$k.log"
        FAILED+=("$k"); continue
    fi
    if OUT="$OUT/modules" "$SRC/build.sh" "$k" --verify; then
        BUILT+=("$k")
    else
        FAILED+=("$k")
    fi
    # Headers are ~100 MB per ABI; don't let a long run fill the disk.
    apt-get purge -y -qq "linux-headers-$k" "linux-headers-${k%-generic}" > /dev/null 2>&1 || true
done
LEFT=$(( ${#TODO[@]} > MAX_BUILDS ? ${#TODO[@]} - MAX_BUILDS : 0 ))

python3 - "$OUT/manifest.json" "$HASH" "$SOURCE_DATE_EPOCH" "$LEFT" \
    "${BUILT[*]:-}" "${FAILED[*]:-}" <<'PY'
import json, sys
out, h, epoch, left, built, failed = sys.argv[1:7]
json.dump({"sourceHash": h, "sourceDateEpoch": int(epoch), "deferred": int(left),
           "built": built.split(), "failed": failed.split()}, open(out, "w"))
PY
echo
echo "built: ${BUILT[*]:-none}; failed: ${FAILED[*]:-none}; deferred to next run: $LEFT"
