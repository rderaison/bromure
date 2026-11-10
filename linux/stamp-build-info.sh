#!/usr/bin/env bash
# stamp-build-info.sh <out.json> — the build's metadata for /state's "build"
# (macOS stamps the same keys into Info.plist): version, build (Jenkins'
# BUILD_NUMBER when set), commit, date. Installed beside the binary as
# bromure-ac.build-info.json; an unstamped binary reports "linux-dev".
set -euo pipefail
OUT=${1:?usage: $0 <out.json>}
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
COMMIT=$(git -C "$ROOT" rev-parse --short=8 HEAD 2>/dev/null || true)
VERSION=$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo linux-dev)
python3 -I - "$OUT" "$VERSION" "${BUILD_NUMBER:+Jenkins #$BUILD_NUMBER}" "$COMMIT" <<'PY'
import json, sys, datetime
out, version, build, commit = sys.argv[1:5]
d = {"version": version, "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")}
if build: d["build"] = build
if commit: d["commit"] = commit
json.dump(d, open(out, "w"), indent=2, sort_keys=True)
PY
