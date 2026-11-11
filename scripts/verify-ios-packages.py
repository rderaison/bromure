#!/usr/bin/env python3
"""Check the iOS app's remote packages against the committed pins.

The TestFlight archive skips Xcode's package plug-in trust prompt (a CI
agent can't click "Trust"), so the plug-in code it runs must be code that
was reviewed: the revisions pinned in the committed Package.resolved, and
nothing a newly published version could slip in.

    python3 -I scripts/verify-ios-packages.py              # the pins alone
    python3 -I scripts/verify-ios-packages.py <spm-dir>    # + the checkouts

Without an argument it checks that the committed Package.resolved pins
every package gen-ios-project.py declares, with a version inside its
requirement and a full commit hash. With the -clonedSourcePackagesDirPath
directory it also checks that each checkout sits at exactly its pinned
revision, with nothing extra checked out. Exits non-zero on any mismatch.

After changing a requirement in gen-ios-project.py, re-pin:

    xcodebuild -resolvePackageDependencies -project ios/BromureRemote/BromureRemote.xcodeproj \\
      -scheme BromureRemote
then review the Package.resolved diff and commit it.
"""
import importlib.util
import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOLVED = os.path.join(REPO, "ios", "BromureRemote", "BromureRemote.xcodeproj",
                        "project.xcworkspace", "xcshareddata", "swiftpm", "Package.resolved")


def declared():
    spec = importlib.util.spec_from_file_location(
        "gen_ios_project", os.path.join(REPO, "scripts", "gen-ios-project.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.PACKAGES


def norm(url):
    url = url.strip().lower()
    return url[:-4] if url.endswith(".git") else url


def version(v):
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", v or "")
    return tuple(int(x) for x in m.groups()) if m else None


def within(kind, low, pinned):
    lo, v = version(low), version(pinned)
    if lo is None or v is None or v < lo:
        return False
    if kind == "upToNextMajorVersion":
        # 0.x: SwiftPM's next major of 0.9.0 is 1.0.0 too.
        return v[0] == lo[0]
    if kind == "upToNextMinorVersion":
        return v[:2] == lo[:2]
    if kind == "exactVersion":
        return v == lo
    return False


def main(argv):
    errors = []
    try:
        with open(RESOLVED) as f:
            pins = json.load(f).get("pins", [])
    except (OSError, ValueError) as e:
        print(f"no usable Package.resolved at {RESOLVED}: {e}", file=sys.stderr)
        return 1
    by_url = {norm(p.get("location", "")): p for p in pins}

    for name, url, kind, low in declared():
        pin = by_url.get(norm(url))
        if pin is None:
            errors.append(f"{name}: not pinned in Package.resolved")
            continue
        state = pin.get("state", {})
        if not within(kind, low, state.get("version")):
            errors.append(f"{name}: pinned {state.get('version')} is outside {kind} {low}")

    for p in pins:
        state = p.get("state", {})
        if p.get("kind") != "remoteSourceControl":
            errors.append(f"{p.get('identity')}: unexpected pin kind {p.get('kind')}")
        if not re.fullmatch(r"[0-9a-f]{40}", state.get("revision", "")):
            errors.append(f"{p.get('identity')}: no full commit revision")
        if "branch" in state:
            errors.append(f"{p.get('identity')}: pinned to a branch")

    if len(argv) > 1:
        checkouts = os.path.join(argv[1], "checkouts")
        wanted = {}
        for p in pins:
            loc = p.get("location", "").rstrip("/")
            d = os.path.basename(loc)
            wanted[d[:-4] if d.endswith(".git") else d] = p
        present = set(os.listdir(checkouts)) if os.path.isdir(checkouts) else set()
        for extra in sorted(present - set(wanted)):
            errors.append(f"checkout {extra}: not in Package.resolved")
        for d, p in sorted(wanted.items()):
            path = os.path.join(checkouts, d)
            if d not in present:
                errors.append(f"checkout {d}: missing")
                continue
            head = subprocess.run(["git", "-C", path, "rev-parse", "HEAD"],
                                  capture_output=True, text=True).stdout.strip()
            dirty = subprocess.run(["git", "-C", path, "status", "--porcelain"],
                                   capture_output=True, text=True).stdout.strip()
            if head != p["state"]["revision"]:
                errors.append(f"checkout {d}: at {head or '?'}, pinned {p['state']['revision']}")
            if dirty:
                errors.append(f"checkout {d}: modified working tree")

    for e in errors:
        print(e, file=sys.stderr)
    if not errors:
        print(f"{len(pins)} iOS package pins OK" + (" (checkouts match)" if len(argv) > 1 else ""))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
