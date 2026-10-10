"""CWE-94: an imported .ovpn must not run code as root in the guest.

Run: python3 -B -m unittest discover -s Tests/GuestGraphicsTests -p "test_openvpn*" -v
"""

import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "Sources/SandboxEngine/Resources/vm-setup/scripts"


def load_script(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), SCRIPTS / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


config = load_script("config-agent")

HOSTILE = """client
dev tun
proto udp
remote vpn.example 1194
script-security 2
up "/bin/sh -c 'touch /tmp/pwned'"
--down /tmp/x.sh
route-up /tmp/y.sh
  TLS-Verify /tmp/z.sh
plugin /tmp/evil.so
iproute /tmp/fake-ip
management 0.0.0.0 7505
config /etc/shadow
log /etc/cron.d/pwn
auth-user-pass /tmp/creds
# up /tmp/commented.sh
<ca>
-----BEGIN CERTIFICATE-----
up looks-like-a-directive-but-is-cert-data
-----END CERTIFICATE-----
</ca>
cipher AES-256-GCM
"""


class OpenVPNConfigTests(unittest.TestCase):
    def test_root_running_directives_are_dropped(self):
        lines, dropped = config.sanitize_ovpn(HOSTILE)
        names, inline = set(), False
        for l in lines:
            s = l.strip()
            if s.startswith("<"):
                inline = not s.startswith("</")
                continue
            if inline or not s or s.startswith("#"):
                continue
            names.add(s.split(None, 1)[0].lower().lstrip("-"))
        for bad in ["script-security", "up", "down", "route-up", "tls-verify", "plugin",
                    "iproute", "management", "config", "log", "auth-user-pass"]:
            self.assertNotIn(bad, names, bad)
            self.assertIn(bad, dropped, bad)
        for good in ["client", "dev", "proto", "remote", "cipher"]:
            self.assertIn(good, names, good)

    def test_inline_blocks_and_comments_are_kept_verbatim(self):
        lines, _ = config.sanitize_ovpn(HOSTILE)
        text = "\n".join(lines)
        self.assertIn("up looks-like-a-directive-but-is-cert-data", text)
        self.assertIn("<ca>", text)
        self.assertIn("</ca>", text)
        self.assertIn("# up /tmp/commented.sh", text)

    def test_launch_overrides_script_security_after_the_config(self):
        src = (SCRIPTS / "openvpn-agent.py").read_text()
        launch = src[src.index("openvpn --config"):]
        launch = launch[:launch.index("% (OVPN_CONFIG")]
        self.assertIn("--script-security 1", launch)
        self.assertLess(launch.index("--config"), launch.index("--script-security 1"))


if __name__ == "__main__":
    unittest.main()
