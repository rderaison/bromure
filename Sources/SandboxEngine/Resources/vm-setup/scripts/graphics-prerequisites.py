#!/usr/bin/python3
"""Inventory the guest GL stack without starting X, a browser, or a VM.

--require-ready validates packaging/configuration prerequisites only. Neither
it nor a DRI loader symbol proves that a host GPU is executing commands.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import sysconfig


PACKAGES = (
    "libgl1-mesa-dri", "mesa-libgallium", "libegl-mesa0", "libglx-mesa0",
    "libgbm1", "libegl1", "libgles2", "mesa-utils", "libxss1", "chromium",
    "google-chrome-stable", "mesa-va-drivers", "libva2", "libva-drm2", "vainfo",
)
LIBRARIES = (
    "libEGL.so.1", "libEGL_mesa.so.0", "libGLESv2.so.2",
    "libGLX_mesa.so.0", "libgbm.so.1",
    "libXss.so.1",  # Display-health/idle diagnostics use XScreenSaverQueryInfo.
)
CAPABILITIES = Path("/etc/bromure/graphics-capabilities.json")
MESA_ROOT = Path("/opt/bromure/mesa-virgl")
VAAPI_ROOT = Path("/opt/bromure/chromium-vaapi")


def run_command(args):
    try:
        env = dict(os.environ, LC_ALL="C")
        result = subprocess.run(args, capture_output=True, text=True,
                                timeout=10, env=env)
        return {"exitCode": result.returncode, "stdout": result.stdout[:16384],
                "stderr": result.stderr[:2048]}
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"exitCode": None, "stdout": "", "stderr": str(error)}


def package_inventory():
    result = run_command([
        "dpkg-query", "-W", "-f=${Package}\t${Version}\t${Architecture}\t${db:Status-Status}\n",
        *PACKAGES,
    ])
    packages = {}
    for line in result["stdout"].splitlines():
        parts = line.split("\t")
        if len(parts) == 4:
            name, version, architecture, status = parts
            packages[name] = {"version": version, "architecture": architecture,
                              "status": status}
    # Optional Chrome/mesa-libgallium packages can be absent; don't treat the
    # overall dpkg-query exit status as evidence that other packages failed.
    return packages


def driver_paths():
    multiarch = sysconfig.get_config_var("MULTIARCH")
    if not multiarch:
        return []
    paths = [Path("/usr/lib") / multiarch / "dri/virtio_gpu_dri.so"]
    return [{"path": str(path), "exists": path.is_file(),
             "target": str(path.resolve())} for path in paths]


def probe_library(name, symbol=None, search_path=None):
    # Loading a DRI module may run library constructors. Keep it in a short
    # lived child so a broken ABI cannot take down the inventory process.
    code = (
        "import ctypes, os, sys; "
        "library = ctypes.CDLL(sys.argv[1], mode=os.RTLD_NOW); "
        "getattr(library, sys.argv[2]) if len(sys.argv) > 2 else None"
    )
    args = [sys.executable, "-B", "-c", code, name]
    if symbol:
        args.append(symbol)
    if search_path:
        args = ["env", "LD_LIBRARY_PATH=" + search_path, *args]
    result = run_command(args)
    return {"loadable": result["exitCode"] == 0,
            "error": result["stderr"] if result["exitCode"] != 0 else None}


def gallium_libraries(drivers):
    # Newer Mesa uses a small libdril loader which opens libgallium later.
    # Its exported entry point alone cannot establish that Gallium is installed.
    libraries = {}
    for driver in drivers:
        if Path(driver["target"]).name == "libdril_dri.so":
            directory = Path(driver["path"]).parent.parent
            paths = sorted(directory.glob("libgallium-*.so"))
            if not paths:
                libraries[str(directory / "libgallium-*.so")] = {
                    "loadable": False, "error": "Missing Gallium implementation"}
            for path in paths:
                libraries[str(path)] = probe_library(str(path))
    return libraries


def contract_issues(capabilities):
    if not isinstance(capabilities, dict):
        return ["Missing or invalid graphics capability marker"]
    if type(capabilities.get("configVersion")) is not int or capabilities["configVersion"] != 1:
        return ["Unsupported graphics configuration contract"]
    backends = capabilities.get("graphicsBackends")
    if not isinstance(backends, list) or not all(name in backends for name in ("software", "virgl")):
        return ["Capability marker does not support software and virgl"]
    if not isinstance(capabilities.get("videoDecodeBackends", []), list):
        return ["Invalid video backend capability list"]
    if "pointerProtocolVersion" in capabilities:
        if (type(capabilities["pointerProtocolVersion"]) is not int
                or capabilities["pointerProtocolVersion"] != 1
                or type(capabilities.get("pointerPort")) is not int
                or capabilities["pointerPort"] != 5821):
            return ["Unsupported pointer configuration contract"]
    if "sharedWindowProtocolVersion" in capabilities or "controllerPort" in capabilities:
        if (type(capabilities.get("sharedWindowProtocolVersion")) is not int
                or capabilities["sharedWindowProtocolVersion"] != 1
                or type(capabilities.get("controllerPort")) is not int
                or capabilities["controllerPort"] != 5832):
            return ["Unsupported shared-window configuration contract"]
    return []


def video_prerequisites(capabilities):
    backends = capabilities.get("videoDecodeBackends") if isinstance(capabilities, dict) else None
    if not isinstance(backends, list) or "virgl-videotoolbox-h264" not in backends:
        return None
    search_path = str(VAAPI_ROOT) + ":" + str(MESA_ROOT / "lib")
    libraries = {}
    for relative in ("libEGL_mesa.so.0", "libGLX_mesa.so.0", "libgbm.so.1",
                     "dri/virtio_gpu_dri.so", "dri/virtio_gpu_drv_video.so"):
        path = str(MESA_ROOT / "lib" / relative)
        libraries[path] = probe_library(path, search_path=search_path)
    for name in ("libva.so.2", "libbromure-va.so.2"):
        path = str(VAAPI_ROOT / name)
        libraries[path] = probe_library(path, "vaInitialize", search_path=search_path)
    try:
        build = (MESA_ROOT / "graphics-build.txt").read_text().splitlines()
    except OSError:
        build = []
    return {"libraries": libraries, "build": build,
            "markerValid": all(line in build for line in (
                "mesa=25.2.8", "video=h264-8bit-progressive", "chromium-vaapi-rgb-abi=1")),
            "vainfo": shutil.which("vainfo"), "hardwareDecodeVerified": None}


def readiness_issues(report):
    issues = contract_issues(report["capabilities"])
    if not any(driver.get("loadable") for driver in report["driDrivers"]):
        issues.append("Virtio GPU DRI loader is missing, unloadable, or lacks its entry point")
    for name, state in report["libraries"].items():
        if not state["loadable"]:
            issues.append("Cannot load " + name)
    for name, path in report["tools"].items():
        if not path:
            issues.append("Missing executable " + name)
    if report["browser"]["exitCode"] != 0:
        issues.append("Selected browser --version did not succeed")
    for name, available in report["guestFiles"].items():
        if not available:
            issues.append("Missing or inaccessible guest file " + name)
    video = report.get("videoPrerequisites")
    if video is not None:
        if not video["markerValid"]:
            issues.append("Missing or incompatible patched Mesa/video build marker")
        if not video["vainfo"]:
            issues.append("Missing executable vainfo")
        for name, state in video["libraries"].items():
            if not state["loadable"]:
                issues.append("Cannot load video dependency " + name)
    return issues


def collect_report(browser):
    paths = driver_paths()
    for driver in paths:
        driver.update(probe_library(driver["path"], "__driDriverGetExtensions_virtio_gpu")
                      if driver["exists"] else {"loadable": False, "error": "Missing file"})
    try:
        capabilities = json.loads(CAPABILITIES.read_text())
    except (OSError, ValueError):
        capabilities = None
    report = {
        "schemaVersion": 1,
        "capabilities": capabilities,
        "packages": package_inventory(),
        "driDrivers": paths,
        "libraries": {**{name: probe_library(name) for name in LIBRARIES},
                      **gallium_libraries(paths)},
        "tools": {name: shutil.which(name) for name in ("glxinfo", "eglinfo", "Xorg")},
        "browser": dict(run_command([browser, "--version"]), command=browser),
        "guestFiles": {
            "/usr/local/bin/config-agent.py": os.access("/usr/local/bin/config-agent.py", os.X_OK),
            "/usr/local/bin/graphics-env.sh": os.access("/usr/local/bin/graphics-env.sh", os.R_OK),
            "/usr/local/bin/graphics-diagnostics.py": os.access("/usr/local/bin/graphics-diagnostics.py", os.X_OK),
        },
        "hostGPUVerified": None,
        "videoPrerequisites": video_prerequisites(capabilities),
        "note": "Packaging check only; run graphics-diagnostics.py in X, verify Chromium and host Metal separately.",
    }
    # Additive marker: older/software images without this protocol stay valid.
    if isinstance(capabilities, dict) and "sharedWindowProtocolVersion" in capabilities:
        for path in ("/usr/local/bin/shared_windows.py", "/usr/local/bin/tab-agent.py",
                     "/usr/local/bin/cdp-agent.py"):
            report["guestFiles"][path] = os.access(path, os.X_OK)
    if isinstance(capabilities, dict) and "pointerProtocolVersion" in capabilities:
        report["guestFiles"]["/usr/local/bin/pointer-agent.py"] = os.access(
            "/usr/local/bin/pointer-agent.py", os.X_OK)
        report["guestFiles"]["/etc/systemd/system/bromure-pointer-agent.service"] = os.access(
            "/etc/systemd/system/bromure-pointer-agent.service", os.R_OK)
    report["issues"] = readiness_issues(report)
    report["readyForGuestProbe"] = not report["issues"]
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--browser", choices=("chromium-browser", "google-chrome-stable"),
                        default="chromium-browser")
    parser.add_argument("--require-ready", action="store_true")
    args = parser.parse_args()
    report = collect_report(args.browser)
    print(json.dumps(report, indent=2))
    return 1 if args.require_ready and not report["readyForGuestProbe"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
