"""Linux-runnable host/guest graphics configuration contract tests.

Run: python3 -B -m unittest discover -s Tests/GuestGraphicsTests -v
These tests don't boot a VM or establish host GPU acceleration.
"""

import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
VM_SETUP = ROOT / "Sources/SandboxEngine/Resources/vm-setup"
SCRIPTS = VM_SETUP / "scripts"


def load_script(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


config = load_script("config-agent")
diagnostics = load_script("graphics-diagnostics")


def chrome_env(cfg):
    stream = io.StringIO()
    # Exercise the actual config writer, without guest filesystem writes or
    # spawning an installed browser.
    with patch("builtins.open") as mocked_open, \
            patch.object(config, "write_chrome_extension_forcelist"):
        mocked_open.return_value.__enter__.return_value = stream
        config.write_chrome_env(cfg)
    return stream.getvalue()


def shell_environment(contents, inherited=None):
    env = {"PATH": os.environ["PATH"]}
    env.update(inherited or {})
    with tempfile.TemporaryDirectory() as directory:
        env_file = Path(directory) / "chrome-env"
        env_file.write_text(contents)
        result = subprocess.run(
            ["sh", "-c", 'set -a; . "$1"; set +a; . "$2"; '
             'printf "%s\\n%s\\n%s\\n" "$GRAPHICS_BACKEND" '
             '"${LIBGL_ALWAYS_SOFTWARE-unset}" "$EXTRA_FLAGS"',
             "graphics-test", str(env_file), str(SCRIPTS / "graphics-env.sh")],
            env=env, capture_output=True, text=True, check=True,
        )
    backend, software, flags = result.stdout.splitlines()
    return backend, software, shlex.split(flags)


class GuestGraphicsConfigTests(unittest.TestCase):
    def test_user_agent_default_and_custom_actual_launch_arguments(self):
        xinitrc = (SCRIPTS / "xinitrc").read_text()
        start = xinitrc.index('    if [ -n "$CHROME_UA" ]; then')
        end = xinitrc.index('    fi', start) + len('    fi')
        launch = xinitrc[start:end]
        for browser in ("chromium", "chrome"):
            for value in (None, "", "  ", "Custom browser agent/1.0", "Agent 'quoted' $(exit 9)"):
                cfg = {"browser": browser, "userAgent": value}
                contents = chrome_env(cfg)
                with tempfile.TemporaryDirectory() as directory:
                    directory = Path(directory)
                    env_file = directory / "chrome-env"
                    env_file.write_text(contents)
                    executable = directory / "browser"
                    executable.write_text('#!/bin/sh\nprintf "%s\\0" "$@"\n')
                    executable.chmod(0o755)
                    result = subprocess.run(["sh", "-c",
                        '. "$1"; CHROME_CMD="$2 --no-first-run"; ' + launch,
                        "ua-test", str(env_file), str(executable)],
                        capture_output=True, check=True)
                    args = result.stdout.decode().rstrip("\0").split("\0")
                expected = ["--no-first-run"]
                if value and value.strip(): expected.append("--user-agent=" + value.strip())
                self.assertEqual(args, expected, (browser, value))

    def test_old_host_keeps_software_gl_and_existing_flags(self):
        backend, software, flags = shell_environment(chrome_env({"gpuAccel": True}))
        self.assertEqual((backend, software), ("software", "1"))
        self.assertIn("--use-angle=gl", flags)

    def test_virgl_enables_gl_and_clears_inherited_software_override(self):
        backend, software, flags = shell_environment(
            chrome_env({"graphicsBackend": "virgl"}), {"LIBGL_ALWAYS_SOFTWARE": "1"})
        self.assertEqual((backend, software), ("virgl", "unset"))
        self.assertIn("--use-gl=angle", flags)
        self.assertIn("--use-angle=gl", flags)
        self.assertIn("--enable-gpu-rasterization", flags)
        self.assertNotIn("--disable-gpu-compositing", flags)

    def test_profile_disabling_gpu_overrides_virgl_and_environment_passthrough(self):
        backend, software, flags = shell_environment(chrome_env({
            "graphicsBackend": "virgl", "gpuAccel": True, "disableGPU": True,
            "chromeEnvExtra": "GRAPHICS_BACKEND=virgl",
        }))
        self.assertEqual((backend, software), ("software", "1"))
        self.assertIn("--disable-gpu", flags)
        self.assertNotIn("--enable-gpu-rasterization", flags)

    def test_webgl_policy_survives_accelerated_selection(self):
        _, _, flags = shell_environment(chrome_env({
            "graphicsBackend": "virgl", "disableWebGL": True,
        }))
        self.assertIn("--disable-webgl", flags)
        self.assertIn("--disable-3d-apis", flags)

    def test_unknown_or_malformed_backend_never_becomes_shell_input(self):
        for value in (None, 1, True, [], {}, "venus", "$(exit 9)", "virgl\nexit 9"):
            with self.subTest(value=value):
                backend, software, _ = shell_environment(chrome_env({"graphicsBackend": value}))
                self.assertEqual((backend, software), ("software", "1"))

    def test_legacy_developer_escape_hatch_is_preserved(self):
        backend, software, _ = shell_environment(chrome_env({
            "chromeEnvExtra": "NO_LIBGL_SOFTWARE=1;LP_NUM_THREADS=8",
        }))
        self.assertEqual((backend, software), ("software", "unset"))

    def test_explicit_developer_compositor_override_is_preserved(self):
        _, _, flags = shell_environment(chrome_env({
            "graphicsBackend": "virgl", "extraChromeFlags": "--disable-gpu-compositing",
        }))
        self.assertIn("--disable-gpu-compositing", flags)

    def test_old_serial_config_with_no_backend_keeps_software_default(self):
        self.assertEqual(shell_environment("EXTRA_FLAGS=''\n")[:2], ("software", "1"))

    def test_shell_unknown_backend_also_falls_back(self):
        self.assertEqual(shell_environment("GRAPHICS_BACKEND=venus\nEXTRA_FLAGS=''\n")[:2],
                         ("software", "1"))

    def test_hardware_movie_flags_and_developer_features_are_merged(self):
        with patch.object(config, "virgl_video_device", return_value="/dev/dri/renderD129"):
            _, _, flags = shell_environment(chrome_env({
                "graphicsBackend": "virgl",
                "extraChromeFlags": "--disable-features=TestDisabled --enable-features=TestEnabled",
            }))
        enabled = [f for f in flags if f.startswith("--enable-features=")]
        disabled = [f for f in flags if f.startswith("--disable-features=")]
        self.assertEqual(len(enabled), 1)
        self.assertEqual(len(disabled), 1)
        self.assertIn("AcceleratedVideoDecodeLinuxGL", enabled[0])
        self.assertIn("TestEnabled", enabled[0])
        self.assertIn("TestDisabled", disabled[0])
        self.assertIn("LcdText", disabled[0])
        self.assertIn("PreferV4L2VideoAcceleration", disabled[0])
        self.assertIn("--hardware-video-device-path=/dev/dri/renderD129", flags)

    def test_software_policy_does_not_enable_hardware_movie_bridge(self):
        with patch.object(config, "virgl_video_device", return_value="/dev/dri/renderD129"):
            _, _, flags = shell_environment(chrome_env({"graphicsBackend": "virgl", "disableGPU": True}))
        self.assertFalse(any("AcceleratedVideoDecodeLinuxGL" in flag for flag in flags))


class GraphicsDiagnosticsTests(unittest.TestCase):
    def test_only_successful_virgl_probe_counts(self):
        cases = [
            ("OpenGL renderer string: virgl (ANGLE Metal Renderer: Apple M4)", 0, True),
            ("OpenGL renderer string: llvmpipe (LLVM 18)", 0, False),
            ("OpenGL renderer string: virgl (LLVMpipe)", 0, False),
            ("OpenGL renderer string: virgl\n    Accelerated: no", 0, False),
            ("OpenGL renderer string: virgl", 1, False),
            ("Error: unable to open display", 1, False),
            ("", 0, False),
        ]
        for output, rc, expected in cases:
            with self.subTest(output=output, rc=rc):
                self.assertEqual(diagnostics.classify_glx(output, rc)[1], expected)

    def test_diagnostics_reads_only_graphics_settings_without_shell_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "chrome-env"
            marker = Path(directory) / "must-not-exist"
            path.write_text(chrome_env({
                "graphicsBackend": "virgl", "chromeEnvExtra": "LP_NUM_THREADS=8",
                "proxyPassword": "not-for-diagnostics", "proxyHost": "example.test",
            }) + f"GALLIUM_DRIVER='$(touch {marker})'\n")
            env = diagnostics.graphics_environment(path, {})
            self.assertEqual(env["GRAPHICS_BACKEND"], "virgl")
            self.assertEqual(env["LP_NUM_THREADS"], "8")
            self.assertNotIn("PROXY_PASSWORD", env)
            self.assertNotIn("EXTRA_FLAGS", env)
            self.assertFalse(marker.exists())

    def test_missing_config_resets_backend_to_legacy(self):
        with tempfile.TemporaryDirectory() as directory:
            env = diagnostics.graphics_environment(Path(directory) / "missing",
                                                   {"GRAPHICS_BACKEND": "virgl"})
            self.assertEqual(env["GRAPHICS_BACKEND"], "software")

    def test_capability_marker_describes_installed_h264_bridge(self):
        data = json.loads((VM_SETUP / "configs/graphics-capabilities.json").read_text())
        self.assertEqual(data["configVersion"], 1)
        self.assertEqual(data["graphicsBackends"], ["software", "virgl"])
        self.assertEqual(data["videoDecodeBackends"], ["software", "virgl-videotoolbox-h264"])
        self.assertEqual(data["chromiumVaapiRgbABI"], 1)


if __name__ == "__main__":
    unittest.main()
