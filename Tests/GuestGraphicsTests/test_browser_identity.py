"""Finding: the macOS User-Agent left Client Hints and navigator.platform
reporting the Linux guest. A non-Linux identity must reach every channel
(identity-agent.py), and a preset's Chrome version must follow the installed
browser (config-agent.py)."""

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from test_guest_graphics import SCRIPTS, chrome_env, config, load_script

agent = load_script("identity-agent")

MAC = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
       "(KHTML, like Gecko) Chrome/157.0.0.0 Safari/537.36")
WINDOWS = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
           "(KHTML, like Gecko) Chrome/157.0.0.0 Safari/537.36")
INSTALLED = (156, "156.0.8078.73")


def env_values(contents):
    values = {}
    for line in contents.splitlines():
        if "=" in line and not line.startswith(("export ", "#")):
            key, value = line.split("=", 1)
            values[key] = value
    return values


class ConfigAgentIdentityTests(unittest.TestCase):
    def env(self, **cfg):
        return env_values(chrome_env(cfg, browser_version=INSTALLED))

    def test_presets_and_linux_default_follow_the_installed_version(self):
        env = self.env(userAgent=MAC, userAgentTracksBrowser=True)
        self.assertIn("Chrome/156.0.0.0", env["CHROME_UA"])
        self.assertIn("Chrome/156.0.0.0", self.env(userAgent="")["CHROME_UA"])
        self.assertIn("X11; Linux x86_64", self.env(userAgent="")["CHROME_UA"])

    def test_custom_user_agent_is_verbatim(self):
        env = self.env(userAgent=MAC)
        self.assertIn("Chrome/157.0.0.0", env["CHROME_UA"])
        self.assertEqual(json.loads(env["CHROME_IDENTITY"].strip("'"))["majorVersion"], 157)

    def test_macos_identity_and_blank_hints_until_applied(self):
        env = self.env(userAgent=MAC, userAgentTracksBrowser=True, hostOSVersion="15.5.1")
        identity = json.loads(env["CHROME_IDENTITY"].strip("'"))
        self.assertEqual(identity, {
            "architecture": "arm", "bitness": "64", "brands": ["Chromium"], "majorVersion": 156,
            "navigatorPlatform": "MacIntel", "platform": "macOS", "platformVersion": "15.5.1"})
        self.assertIn("UACHOverrideBlank", env["EXTRA_FLAGS"])

    def test_windows_identity(self):
        identity = json.loads(self.env(userAgent=WINDOWS, browser="chrome")["CHROME_IDENTITY"].strip("'"))
        self.assertEqual((identity["platform"], identity["navigatorPlatform"], identity["architecture"]),
                         ("Windows", "Win32", "x86"))
        self.assertEqual(identity["brands"], ["Chromium", "Google Chrome"])

    def test_linux_and_unknown_identities_keep_native_values(self):
        for ua in ("", "Mozilla/5.0 (X11; Linux x86_64) Chrome/1.0.0.0", "Custom agent/1.0"):
            env = self.env(userAgent=ua)
            self.assertNotIn("CHROME_IDENTITY", env, ua)
            self.assertNotIn("UACHOverrideBlank", env.get("EXTRA_FLAGS", ""), ua)

    def test_bad_host_version_falls_back(self):
        identity = config.browser_identity({"hostOSVersion": "15; rm -rf"}, MAC)
        self.assertEqual(identity["platformVersion"], "15.0.0")


class BrandListTests(unittest.TestCase):
    def header(self, major, names):
        return ", ".join(f'"{b["brand"]}";v="{b["version"]}"' for b in agent.grease_brands(major, names))

    def test_grease_matches_chromium(self):
        # Sec-CH-UA as sent by real Chrome 120 and 124, and by this image's
        # Chromium 156 / Chrome 157 (measured).
        self.assertEqual(self.header(120, ["Chromium", "Google Chrome"]),
                         '"Not_A Brand";v="8", "Chromium";v="120", "Google Chrome";v="120"')
        self.assertEqual(self.header(124, ["Chromium", "Google Chrome"]),
                         '"Chromium";v="124", "Google Chrome";v="124", "Not-A.Brand";v="99"')
        self.assertEqual(self.header(156, ["Chromium"]), '"Not:A-Brand";v="8", "Chromium";v="156"')
        self.assertEqual(self.header(157, ["Chromium"]), '"Chromium";v="157", "Not-A.Brand";v="99"')

    def test_metadata_keeps_native_brands_and_engine_version(self):
        native = {"brands": [{"brand": "Not:A-Brand", "version": "8"}, {"brand": "Chromium", "version": "156"}],
                  "fullVersionList": [], "fullVersion": "156.0.8078.73"}
        identity = {"platform": "macOS", "platformVersion": "15.5.0", "architecture": "arm",
                    "bitness": "64", "majorVersion": 156, "brands": ["Chromium"]}
        meta = agent.user_agent_metadata(identity, native)
        self.assertEqual(meta["brands"], native["brands"])
        self.assertEqual(meta["fullVersionList"], [{"brand": "Not:A-Brand", "version": "8.0.0.0"},
                                                   {"brand": "Chromium", "version": "156.0.8078.73"}])
        self.assertEqual((meta["platform"], meta["mobile"], meta["model"]), ("macOS", False, ""))

    def test_metadata_rebuilds_a_list_missing_google_chrome(self):
        native = {"brands": [{"brand": "Chromium", "version": "157"}, {"brand": "Not-A.Brand", "version": "99"}],
                  "fullVersion": "157.0.8103.78"}
        identity = {"platform": "Windows", "platformVersion": "19.0.0", "architecture": "x86",
                    "bitness": "64", "majorVersion": 157, "brands": ["Chromium", "Google Chrome"]}
        meta = agent.user_agent_metadata(identity, native)
        self.assertEqual(sorted(b["brand"] for b in meta["brands"]),
                         ["Chromium", "Google Chrome", "Not-A.Brand"])
        self.assertIn({"brand": "Google Chrome", "version": "157.0.8103.78"}, meta["fullVersionList"])

    def test_custom_major_version_re_versions_real_brands(self):
        native = {"brands": [{"brand": "Not:A-Brand", "version": "8"}, {"brand": "Chromium", "version": "156"}],
                  "fullVersion": "156.0.8078.73"}
        identity = {"platform": "macOS", "platformVersion": "15.0.0", "architecture": "arm",
                    "bitness": "64", "majorVersion": 150, "brands": ["Chromium"]}
        meta = agent.user_agent_metadata(identity, native)
        self.assertIn({"brand": "Chromium", "version": "150"}, meta["brands"])
        self.assertIn({"brand": "Chromium", "version": "150.0.0.0"}, meta["fullVersionList"])


class AgentSequencingTests(unittest.TestCase):
    IDENTITY = {"platform": "macOS", "platformVersion": "15.0.0", "architecture": "arm", "bitness": "64",
                "navigatorPlatform": "MacIntel", "majorVersion": 156}

    def make(self, **kw):
        self.sent = []
        self.now = [0.0]
        a = agent.IdentityAgent(lambda m, p, s: self.sent.append((m, s)), MAC, self.IDENTITY, {"platform": "macOS"},
                                clock=lambda: self.now[0], **kw)
        return a

    def methods(self, session):
        return [m for m, s in self.sent if s == session]

    def test_new_tab_is_released_only_after_its_page_has_the_identity(self):
        a = self.make()
        a.attached({"sessionId": "T", "waitingForDebugger": True, "targetInfo": {"type": "tab", "url": ""}})
        self.assertNotIn("Runtime.runIfWaitingForDebugger", self.methods("T"))
        a.attached({"sessionId": "P", "waitingForDebugger": False,
                    "targetInfo": {"type": "page", "url": "https://example.com/"}}, parent="T")
        page = self.methods("P")
        self.assertEqual(page[:3], ["Emulation.setUserAgentOverride", "Page.enable",
                                    "Page.addScriptToEvaluateOnNewDocument"])
        # The tab's release is the last thing sent, after the page's override.
        self.assertEqual(self.sent[-1], ("Runtime.runIfWaitingForDebugger", "T"))
        self.assertLess(self.sent.index(("Emulation.setUserAgentOverride", "P")), len(self.sent) - 1)
        self.assertEqual(a.held_tabs, {})

    def test_held_tab_without_a_page_is_released_after_the_hold(self):
        a = self.make()
        a.attached({"sessionId": "T", "waitingForDebugger": True, "targetInfo": {"type": "tab"}})
        a.tick()
        self.assertNotIn("Runtime.runIfWaitingForDebugger", self.methods("T"))
        self.now[0] = a.TAB_HOLD
        a.tick()
        self.assertIn("Runtime.runIfWaitingForDebugger", self.methods("T"))

    def test_paused_targets_get_the_identity_before_they_run(self):
        a = self.make()
        for kind, override in (("iframe", "Emulation.setUserAgentOverride"),
                               ("worker", "Network.setUserAgentOverride"),
                               ("shared_worker", "Network.setUserAgentOverride"),
                               ("service_worker", "Network.setUserAgentOverride")):
            a.attached({"sessionId": kind, "waitingForDebugger": True,
                        "targetInfo": {"type": kind, "parentId": "x"}})
            methods = self.methods(kind)
            self.assertLess(methods.index(override), methods.index("Runtime.runIfWaitingForDebugger"), kind)
            self.assertIn("Target.setAutoAttach", methods, kind)
            if kind.endswith("worker"):
                self.assertLess(methods.index("Runtime.evaluate"),
                                methods.index("Runtime.runIfWaitingForDebugger"), kind)

    def test_start_page_opens_once_in_the_blank_tab(self):
        a = self.make(start_url="https://start.example/")
        a.attached({"sessionId": "P", "targetInfo": {"type": "page", "url": "about:blank"}})
        a.attached({"sessionId": "Q", "targetInfo": {"type": "page", "url": "about:blank"}})
        self.assertIn("Page.navigate", self.methods("P"))
        self.assertNotIn("Page.navigate", self.methods("Q"))

    def test_restored_tabs_reload_once_new_ones_do_not(self):
        a = self.make(reload_existing=True)
        a.attached({"sessionId": "R", "targetInfo": {"type": "page", "url": "https://restored.example/"}})
        a.attached({"sessionId": "N", "waitingForDebugger": True,
                    "targetInfo": {"type": "page", "url": "https://new.example/"}})
        self.assertIn("Page.reload", self.methods("R"))
        self.assertNotIn("Page.reload", self.methods("N"))

    def test_browser_level_attach_covers_tabs_and_unowned_workers(self):
        a = self.make()
        a.start()
        method, session = self.sent[0]
        self.assertEqual((method, session), ("Target.setAutoAttach", None))

    def test_platform_script_patches_navigator_and_worker_navigator(self):
        script = agent.platform_script("Win32")
        self.assertIn('return "Win32"', script)
        self.assertIn("self.Navigator || self.WorkerNavigator", script)


class WebSocketTests(unittest.TestCase):
    def setUp(self):
        import socket
        self.ours, self.browser = socket.socketpair()
        self.devtools = object.__new__(agent.DevTools)
        self.devtools.sock, self.devtools.buf, self.devtools.next_id = self.ours, b"", 0

    def tearDown(self):
        self.ours.close()
        self.browser.close()

    def test_ping_is_answered_and_returns_control(self):
        self.browser.sendall(bytes([0x89, 4]) + b"ping")
        self.assertIsNone(self.devtools.receive(timeout=1))
        pong = self.browser.recv(64)
        self.assertEqual(pong[0], 0x8A)
        self.assertEqual(bytes(b ^ pong[2 + i % 4] for i, b in enumerate(pong[6:])), b"ping")

    def test_fragmented_message_is_reassembled(self):
        body = b'{"id": 7, "result": {}}'
        self.browser.sendall(bytes([0x01, 10]) + body[:10] + bytes([0x80, len(body) - 10]) + body[10:])
        self.assertEqual(self.devtools.receive(timeout=1), {"id": 7, "result": {}})


class XinitrcIdentityTests(unittest.TestCase):
    def block(self):
        text = (SCRIPTS / "xinitrc").read_text()
        start = text.index("_IDENTITY_URL=\nif")
        return text[start:text.index("\nfi\n", start) + 4]

    def run_block(self, identity, url):
        with tempfile.TemporaryDirectory() as d:
            launcher = Path(d) / "launch"
            launcher.write_text("#!/bin/sh\necho \"launched $*\" > \"$LOG\"\n")
            launcher.chmod(0o755)
            block = self.block().replace("/usr/local/bin/resilient-launch.sh", str(launcher))
            log = Path(d) / "log"
            out = subprocess.run(["sh", "-c", f'CHROME_IDENTITY="$1"; CHROME_URL="$2"; export LOG="$3"\n{block}\n'
                                  'wait; printf "%s|%s" "$CHROME_URL" "$_IDENTITY_URL"',
                                  "x", identity, url, str(log)], capture_output=True, text=True, check=True)
            return out.stdout, log.read_text() if log.exists() else ""

    def test_identity_defers_start_page_to_the_agent(self):
        out, log = self.run_block('{"platform":"macOS"}', "https://start.example/")
        self.assertEqual(out, "about:blank|https://start.example/")
        self.assertIn("identity-agent.py", log)

    def test_no_identity_changes_nothing(self):
        out, log = self.run_block("", "https://start.example/")
        self.assertEqual(out, "https://start.example/|")
        self.assertEqual(log, "")


if __name__ == "__main__":
    unittest.main()
