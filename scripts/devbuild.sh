#!/bin/bash
# devbuild.sh — build a named, immutable Bromure Agentic Coding bundle from any
# git ref, outside .build, so several builds can exist (and run) side by side
# and the one being worked in is never rebuilt under itself.
#
#   scripts/devbuild.sh <name> [<git-ref>] [--from-worktree <dir>] [--force]
#   scripts/devbuild.sh --prod <tag>            # sugar: name prod-<version>, cached
#
# <git-ref> defaults to HEAD, resolved to a commit when the script starts
# (uncommitted changes are not part of it; commit them, or build a branch).
#
# Output: ~/Library/Application Support/<folder>-builds/<name>/
#           Bromure Agentic Coding.app   the bundle (BromureBuildName stamped)
#           build.json                   ref, sha, dirty, date, builder, version
# where <folder> is the dev flavor's data folder (BromureACDev). The `stable`
# symlink next to them is the build the default state runs on; `bromure-ac
# build promote <name>` repoints it. This script only makes the very first
# build stable (there is nothing else it could be).
#
# How: a git worktree per name under .worktrees/<name> (kept, so a rebuild of
# the same name is incremental), with .env.local (identity and the dev
# flavor), the provisioning profile and a clone of vendor/ (GhosttyKit) laid
# in; `./build.sh bromure-ac` runs inside it, so the main checkout's .build
# and bundle are untouched. A ref
# that predates the builds-and-states branch gets its commits cherry-picked
# first (identity from .env.local, the vmnet entitlement under your team,
# --state, the instance lock, the control-socket quit): that is what makes a
# production tag buildable and drivable here. A conflict stops the build with
# the worktree left for you to look at.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATES_BRANCH="${BROMURE_STATES_BRANCH:-feat/builds-and-states}"

REF=""; NAME=""; FROM_WORKTREE=""; FORCE=0; PROD=""
usage() { echo "usage: $0 <name> [<git-ref>] [--from-worktree <dir>] [--force] | --prod <tag>" >&2; exit 2; }
while [ $# -gt 0 ]; do
    case "$1" in
        --from-worktree) FROM_WORKTREE="$2"; shift 2 ;;
        --force) FORCE=1; shift ;;
        --prod) PROD="$2"; REF="$2"; shift 2 ;;
        -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
        -*) echo "unknown option $1" >&2; usage ;;
        *)
            if [ -z "$NAME" ]; then NAME="$1"
            elif [ -z "$REF" ]; then REF="$1"
            else echo "unexpected argument $1" >&2; usage; fi
            shift ;;
    esac
done
if [ -n "$PROD" ]; then
    # agentic-coding-v5.4.0 → prod-5.4.0
    NAME="${NAME:-prod-${PROD##*-v}}"
fi
REF="${REF:-HEAD}"
[ -n "$NAME" ] || usage
case "$NAME" in ""|.|..|.*|*/*|*:*|stable|stable.prev) echo "error: '$NAME' isn't a build name" >&2; exit 2 ;; esac
[ -f "$ROOT/.env.local" ] || { echo "error: $ROOT/.env.local missing (see BUILD_INSTRUCTIONS.md)" >&2; exit 1; }

# The data folder of the dev flavor names the builds folder (<folder>-builds).
# shellcheck disable=SC1091
FOLDER=$(cd "$ROOT" && set -a && . ./.env.local && set +a && [ "${BROMURE_DEV:-0}" = 1 ] && echo BromureACDev || echo BromureAC)
BUILDS="$HOME/Library/Application Support/${FOLDER}-builds"
DEST="$BUILDS/$NAME"
APP_NAME="Bromure Agentic Coding.app"

if [ -d "$DEST/$APP_NAME" ] && [ "$FORCE" = 0 ]; then
    if [ -n "$PROD" ]; then
        echo "$NAME already built ($(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["shortSha"], d["builtAt"])' "$DEST/build.json" 2>/dev/null)); --force rebuilds."
        echo "$DEST"
        exit 0
    fi
    echo "error: $DEST exists; builds are immutable — pick another name or --force" >&2
    exit 1
fi

# The ref is pinned to a commit now: the checkout's HEAD may move while
# the build runs (a commit made meanwhile), and build.json must describe
# what was built.
ref_sha=$(git -C "$ROOT" rev-parse --verify --quiet "$REF^{commit}") || { echo "error: no such ref: $REF" >&2; exit 1; }

# 1. The worktree.
if [ -n "$FROM_WORKTREE" ]; then
    WT="$(cd "$FROM_WORKTREE" && pwd)"
else
    WT="$ROOT/.worktrees/$NAME"
    if [ -d "$WT" ]; then
        echo "==> Reusing worktree $WT (checking out $REF)"
        git -C "$WT" checkout --quiet --detach "$ref_sha"
    else
        mkdir -p "$ROOT/.worktrees"
        echo "==> git worktree add $WT $REF"
        git -C "$ROOT" worktree add --quiet --detach "$WT" "$ref_sha"
    fi
fi

# 2. The builds-and-states commits, when the ref predates them. The range is
#    main..<states branch>: identity + states, in order. A worktree handed in
#    with --from-worktree is taken as is (its commits were laid on by hand,
#    maybe with conflicts resolved: cherry-picking again would conflict on
#    every file); so is one whose history already carries the patches
#    (git cherry: by patch id, since a resolved pick has a new sha).
needs_states() {
    [ -n "$FROM_WORKTREE" ] && return 1
    git -C "$WT" merge-base --is-ancestor "$STATES_BRANCH" HEAD 2>/dev/null && return 1
    local base; base=$(git -C "$WT" merge-base main "$STATES_BRANCH")
    # A "+" line is a patch of the range that HEAD doesn't carry yet.
    if git -C "$WT" cherry HEAD "$STATES_BRANCH" "$base" | grep -q '^+'; then return 0; fi
    return 1
}
if needs_states; then
    base=$(git -C "$WT" merge-base main "$STATES_BRANCH")
    range="$base..$STATES_BRANCH"
    n=$(git -C "$WT" rev-list --count "$range")
    echo "==> $REF lacks the builds-and-states commits; cherry-picking $n ($range)"
    if ! git -C "$WT" cherry-pick --quiet "$range"; then
        echo "error: cherry-pick conflicted in $WT — resolve there (git cherry-pick --continue), then:" >&2
        echo "       $0 $NAME $REF --from-worktree $WT" >&2
        exit 1
    fi
fi

# 3. What build.sh needs and git doesn't carry: the signing setup and the
#    Ghostty framework. vendor/ is cloned (cp -c, instant on APFS), not
#    symlinked: a ref pinning another ghostty commit rebuilds into its own
#    copy, never into the main checkout's.
ln -sfn "$ROOT/.env.local" "$WT/.env.local"
for p in "$ROOT"/*.provisionprofile; do [ -f "$p" ] && ln -sfn "$p" "$WT/$(basename "$p")"; done
if [ ! -d "$WT/vendor" ] && [ -d "$ROOT/vendor" ]; then
    cp -cR "$ROOT/vendor" "$WT/vendor" 2>/dev/null || cp -R "$ROOT/vendor" "$WT/vendor"
fi

# 4. Build in the worktree (its own .build).
echo "==> ./build.sh bromure-ac in $WT"
( cd "$WT" && ./build.sh bromure-ac ) | tail -3
SRC_APP="$WT/.build/arm64-apple-macosx/release/$APP_NAME"
[ -d "$SRC_APP" ] || { echo "error: no bundle at $SRC_APP" >&2; exit 1; }

# 5. The immutable copy: name stamped, re-signed (the stamp changes the
#    Info.plist, which the seal covers), verified, described.
mkdir -p "$BUILDS"
rm -rf "$DEST.tmp"; mkdir -p "$DEST.tmp"
ditto "$SRC_APP" "$DEST.tmp/$APP_NAME"
PLIST="$DEST.tmp/$APP_NAME/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :BromureBuildName" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :BromureBuildName string $NAME" "$PLIST"
# shellcheck disable=SC1091
SIGN_ID=$(cd "$ROOT" && set -a && . ./.env.local && set +a && echo "${CODESIGN_IDENTITY:--}")
ENT="$WT/.build/arm64-apple-macosx/release/bromure-ac.entitlements"
codesign --force --sign "$SIGN_ID" --entitlements "$ENT" --options runtime "$DEST.tmp/$APP_NAME"
codesign --verify --deep --strict "$DEST.tmp/$APP_NAME"

sha=$(git -C "$WT" rev-parse HEAD)
dirty=false; git -C "$WT" diff --quiet HEAD -- 2>/dev/null || dirty=true
cat > "$DEST.tmp/build.json" <<EOF
{
  "name": "$NAME",
  "ref": "$REF",
  "refSha": "$ref_sha",
  "sha": "$sha",
  "shortSha": "${sha:0:8}",
  "dirty": $dirty,
  "statesCommitsAdded": $([ "$sha" = "$ref_sha" ] && echo false || echo true),
  "builtAt": "$(/usr/libexec/PlistBuddy -c 'Print :BromureBuildDate' "$PLIST")",
  "version": "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")",
  "bundleId": "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")",
  "builder": "$(whoami)@$(hostname -s) scripts/devbuild.sh",
  "worktree": "$WT"
}
EOF
rm -rf "$DEST"
mv "$DEST.tmp" "$DEST"
echo "==> $DEST"
cat "$DEST/build.json"

# 6. The first build is the stable one (nothing else could be): the `stable`
#    symlink, ~/.local/bin/bromure-ac and the Finder alias. Later builds are
#    promoted by hand: bromure-ac build promote <name>.
if [ ! -e "$BUILDS/stable" ]; then
    ln -sfn "$NAME" "$BUILDS/stable"
    echo "==> first build: stable → $NAME"
    "$DEST/$APP_NAME/Contents/MacOS/bromure-ac" build link
fi
