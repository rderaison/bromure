"""Exercise the headless image packaging gate, without a GPU or X server."""

import contextlib
import ctypes.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from test_guest_graphics import load_script, VM_SETUP


prerequisites = load_script("graphics-prerequisites")


class GraphicsPrerequisitesTests(unittest.TestCase):
    def report(self, capabilities=None, missing_library=None, browser_exit=0, missing_guest=None):
        marker = capabilities or VM_SETUP / "configs/graphics-capabilities.json"

        def library(name, symbol=None, search_path=None):
            return {"loadable": name != missing_library, "error": None}

        with patch.object(prerequisites, "CAPABILITIES", marker), \
                patch.object(prerequisites, "driver_paths", return_value=[{
                    "path": "/test/dri/virtio_gpu_dri.so", "exists": True,
                    "target": "/test/dri/virtio_gpu_dri.so"}]), \
                patch.object(prerequisites, "probe_library", side_effect=library), \
                patch.object(prerequisites, "video_prerequisites", return_value=None), \
                patch.object(prerequisites, "package_inventory", return_value={}), \
                patch.object(prerequisites.shutil, "which", side_effect=lambda name: "/bin/" + name), \
                patch.object(prerequisites.os, "access", side_effect=lambda path, mode: path != missing_guest), \
                patch.object(prerequisites, "run_command", return_value={
                    "exitCode": browser_exit, "stdout": "Chromium test", "stderr": ""}):
            return prerequisites.collect_report("chromium-browser")

    def test_complete_packaging_does_not_claim_host_acceleration(self):
        report = self.report()
        self.assertTrue(report["readyForGuestProbe"])
        self.assertIsNone(report["hostGPUVerified"])
        # Missing optional package metadata doesn't defeat actual loadability.
        self.assertEqual(report["packages"], {})

    def test_shared_window_contract_is_optional_but_complete_when_advertised(self):
        marker = json.loads((VM_SETUP / 'configs/graphics-capabilities.json').read_text())
        self.assertEqual(marker['sharedWindowProtocolVersion'], 1)
        self.assertEqual(marker['controllerPort'], 5832)
        self.assertFalse(self.report(missing_guest='/usr/local/bin/shared_windows.py')['readyForGuestProbe'])
        self.assertFalse(self.report(missing_guest='/usr/local/bin/tab-agent.py')['readyForGuestProbe'])
        self.assertFalse(self.report(missing_guest='/usr/local/bin/cdp-agent.py')['readyForGuestProbe'])
        for changes in ({'controllerPort': 1}, {'sharedWindowProtocolVersion': True},
                        {'sharedWindowProtocolVersion': 2}):
            self.assertTrue(prerequisites.contract_issues(dict(marker, **changes)))
        marker.pop('sharedWindowProtocolVersion')
        self.assertTrue(prerequisites.contract_issues(marker))
        marker.pop('controllerPort')
        self.assertFalse(prerequisites.contract_issues(marker))

    def test_broken_egl_or_browser_fails_packaging_gate(self):
        for kwargs in ({"missing_library": "libEGL_mesa.so.0"},
                       {"missing_library": "libXss.so.1"}, {"browser_exit": 127}):
            with self.subTest(kwargs=kwargs):
                report = self.report(**kwargs)
                self.assertFalse(report["readyForGuestProbe"])
                self.assertTrue(report["issues"])
                with patch.object(prerequisites, "collect_report", return_value=report), \
                        patch("sys.argv", ["graphics-prerequisites.py", "--require-ready"]), \
                        contextlib.redirect_stdout(io.StringIO()) as output:
                    self.assertEqual(prerequisites.main(), 1)
                self.assertFalse(json.loads(output.getvalue())["readyForGuestProbe"])

    def test_legacy_or_malformed_marker_fails_without_crashing(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "capabilities.json"
            self.assertFalse(self.report(capabilities=marker)["readyForGuestProbe"])
            for contents in ("{", "null", '{"configVersion":true}',
                             '{"configVersion":1,"graphicsBackends":[{}]}'):
                marker.write_text(contents)
                self.assertFalse(self.report(capabilities=marker)["readyForGuestProbe"])

    def test_libdril_without_gallium_is_not_sufficient(self):
        with tempfile.TemporaryDirectory() as directory:
            driver = {"path": directory + "/dri/virtio_gpu_dri.so",
                      "target": directory + "/dri/libdril_dri.so"}
            libraries = prerequisites.gallium_libraries([driver])
            self.assertEqual(len(libraries), 1)
            self.assertFalse(next(iter(libraries.values()))["loadable"])

    def test_video_marker_requires_patched_stack_and_facade(self):
        capabilities = {"videoDecodeBackends": ["virgl-videotoolbox-h264"]}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(prerequisites, "MESA_ROOT", root), \
                    patch.object(prerequisites, "VAAPI_ROOT", root / "facade"), \
                    patch.object(prerequisites, "probe_library", return_value={"loadable": True}), \
                    patch.object(prerequisites.shutil, "which", return_value="/bin/vainfo"):
                video = prerequisites.video_prerequisites(capabilities)
                report = self.report()
                report["videoPrerequisites"] = video
                self.assertTrue(prerequisites.readiness_issues(report))
                (root / "graphics-build.txt").write_text(
                    "mesa=25.2.8\nvideo=h264-8bit-progressive\nchromium-vaapi-rgb-abi=1\n")
                video = prerequisites.video_prerequisites(capabilities)
                report["videoPrerequisites"] = video
                self.assertEqual(prerequisites.readiness_issues(report), [])
                self.assertIsNone(video["hardwareDecodeVerified"])
                video["libraries"][str(root / "facade/libva.so.2")]["loadable"] = False
                self.assertTrue(prerequisites.readiness_issues(report))

    def test_real_loader_checks_libraries_and_entry_points(self):
        libc = ctypes.util.find_library("c")
        self.assertTrue(prerequisites.probe_library(libc, "malloc")["loadable"])
        self.assertFalse(prerequisites.probe_library(libc, "__bromure_missing_symbol")["loadable"])
        self.assertFalse(prerequisites.probe_library("/nonexistent/bromure.so")["loadable"])

    def test_pointer_prerequisites_are_required_only_when_advertised(self):
        missing = "/usr/local/bin/pointer-agent.py"
        self.assertFalse(self.report(missing_guest=missing)["readyForGuestProbe"])
        self.assertFalse(self.report(missing_guest="/etc/systemd/system/bromure-pointer-agent.service")["readyForGuestProbe"])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "legacy.json"
            marker = json.loads((VM_SETUP / "configs/graphics-capabilities.json").read_text())
            marker.pop("pointerProtocolVersion")
            marker.pop("pointerPort")
            path.write_text(json.dumps(marker))
            self.assertTrue(self.report(capabilities=path, missing_guest=missing)["readyForGuestProbe"])
            marker.update(pointerProtocolVersion=1, pointerPort=1)
            path.write_text(json.dumps(marker))
            self.assertFalse(self.report(capabilities=path)["readyForGuestProbe"])


if __name__ == "__main__":
    unittest.main()
