#!/usr/bin/python3
"""Report guest graphics evidence without exposing browser/profile settings.

Run as the chrome user in the browser's X session (DISPLAY/XAUTHORITY must
match). --require-virgl fails unless GLX identifies a VirGL renderer; it does
not certify Chromium's selected compositor or Metal execution on the host.
"""

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess


GRAPHICS_ENV_KEYS = {
    "GRAPHICS_BACKEND", "NO_LIBGL_SOFTWARE", "LIBGL_ALWAYS_SOFTWARE",
    "MESA_LOADER_DRIVER_OVERRIDE", "GALLIUM_DRIVER", "DRI_PRIME",
    "LP_NUM_THREADS",
}


def graphics_environment(path, inherited):
    """Read only graphics assignments. Never execute the sourced config."""
    env = dict(inherited)
    # Match xinitrc: no explicit selection means the legacy backend.
    env["GRAPHICS_BACKEND"] = "software"
    try:
        lines = Path(path).read_text().splitlines()
    except FileNotFoundError:
        return env
    for line in lines:
        try:
            parts = shlex.split(line, comments=True)
        except ValueError:
            continue
        if parts and parts[0] == "export":
            parts = parts[1:]
        if len(parts) != 1 or "=" not in parts[0]:
            continue
        key, value = parts[0].split("=", 1)
        if key in GRAPHICS_ENV_KEYS:
            env[key] = value
    return env


def classify_glx(output, returncode):
    match = re.search(r"^OpenGL renderer string:\s*(.+)$", output, re.MULTILINE)
    renderer = match.group(1).strip() if match else None
    software = bool(renderer and any(
        name in renderer.lower() for name in ("llvmpipe", "softpipe", "swiftshader")
    ))
    explicitly_unaccelerated = bool(re.search(
        r"^\s*Accelerated:\s*no\b", output, re.MULTILINE | re.IGNORECASE))
    virgl = bool(returncode == 0 and renderer and
                 "virgl" in renderer.lower() and
                 not software and not explicitly_unaccelerated)
    return renderer, virgl


def drm_devices(root=Path("/sys/class/drm")):
    devices = []
    for node in sorted(root.glob("renderD*")):
        device = node / "device"
        entry = {"node": "/dev/dri/" + node.name}
        driver = device / "driver"
        if driver.is_symlink():
            entry["driver"] = driver.resolve().name
        # Virtio device IDs are useful evidence, not acceleration proof.
        for name in ("device", "vendor"):
            try:
                entry[name] = (device / name).read_text().strip()
            except OSError:
                pass
        devices.append(entry)
    return devices


def collect_report():
    env = graphics_environment("/tmp/bromure/chrome-env", os.environ)
    helper = Path(__file__).resolve().with_name("graphics-env.sh")
    report = {
        "configVersion": 1,
        "requestedBackend": env["GRAPHICS_BACKEND"],
        "drmRenderNodes": drm_devices(),
        "guestReportsVirgl": False,
        "hostGPUVerified": None,
        "note": "GLX probe only. Verify Chromium via chrome://gpu and host GPU activity separately.",
    }
    try:
        # Use the same shell helper as xinitrc, not a second implementation
        # of backend/environment policy. Positional argument avoids quoting
        # any filesystem paths as shell program text.
        result = subprocess.run(
            ["sh", "-c", '. "$1" || exit; exec glxinfo -B', "graphics-probe", str(helper)],
            env=env, capture_output=True, text=True, timeout=10,
        )
        renderer, virgl = classify_glx(result.stdout, result.returncode)
        report.update({
            "renderer": renderer,
            "guestReportsVirgl": virgl,
            "probeExitCode": result.returncode,
            "glxInfo": result.stdout[:8192],
            "probeError": result.stderr[:2048],
        })
    except (OSError, subprocess.TimeoutExpired) as error:
        report["probeError"] = str(error)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--require-virgl", action="store_true")
    args = parser.parse_args()
    report = collect_report()
    print(json.dumps(report, indent=2))
    return 1 if args.require_virgl and not report["guestReportsVirgl"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
