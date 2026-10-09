"""CWE-78: IKEv2 passphrase and proxy password must not reach a root shell.

config-agent.py runs as root in the guest. These tests load that script
and check the two interpolations (openssl -passin, strongSwan updown)
plus the swanctl.conf quoting that feeds updown, which strongSwan itself
executes through a shell.

Run: python3 -B -m unittest discover -s Tests/GuestGraphicsTests -v
"""

import base64
import importlib.util
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "Sources/SandboxEngine/Resources/vm-setup/scripts"


def load_script(name):
    spec = importlib.util.spec_from_file_location(
        name, SCRIPTS / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


config = load_script("config-agent")


def parse_swanctl_string(text, index):
    """Decode one swanctl quoted string starting at index.

    Mirrors strongSwan's settings lexer (<str> state): \\n \\r \\t and
    \\X escapes, raw CR discarded, closing quote ends the string.
    Returns (value, index_after_quote).
    """
    if text[index] != '"':
        raise AssertionError("expected opening quote at %s" % index)
    index += 1
    out = []
    while index < len(text):
        char = text[index]
        if char == '"':
            return "".join(out), index + 1
        if char == "\\":
            if index + 1 >= len(text):
                raise AssertionError("unterminated swanctl escape")
            nxt = text[index + 1]
            out.append({"n": "\n", "r": "\r", "t": "\t"}.get(nxt, nxt))
            index += 2
            continue
        if char == "\r":
            index += 1
            continue
        out.append(char)
        index += 1
    raise AssertionError("unterminated swanctl string")


def quoted_values(text):
    """Every double-quoted swanctl string in text, in order."""
    values = []
    index = 0
    while index < len(text):
        if text[index] == '"':
            value, index = parse_swanctl_string(text, index)
            values.append(value)
            continue
        index += 1
    return values


class IKEv2ShellInjectionTests(unittest.TestCase):
    def test_pkcs12_passphrase_is_stdin_not_an_argument(self):
        passphrase = "x; id #"
        argv, stdin = config.pkcs12_openssl_invocation(
            "/tmp/bromure/client.p12", passphrase,
            ["-clcerts", "-nokeys"], "/etc/swanctl/x509/client.crt")
        self.assertIsInstance(argv, list)
        self.assertEqual(argv[0], "openssl")
        self.assertEqual(argv[1:4], ["pkcs12", "-in", "/tmp/bromure/client.p12"])
        self.assertIn("-passin", argv)
        self.assertEqual(argv[argv.index("-passin") + 1], "stdin")
        self.assertNotIn(passphrase, argv)
        joined = " ".join(argv)
        self.assertNotIn(passphrase, joined)
        self.assertNotIn("pass:", joined)
        self.assertEqual(stdin, b"x; id #\n")

        empty_argv, empty_stdin = config.pkcs12_openssl_invocation(
            "/tmp/c.p12", "", ["-nocerts", "-nodes"], "/tmp/c.key")
        self.assertEqual(empty_stdin, b"\n")
        self.assertNotIn("pass:", " ".join(empty_argv))

        for bad in ("has\nnewline", "has\rreturn", "has\x00nul"):
            with self.assertRaises(ValueError):
                config.pkcs12_openssl_invocation(
                    "/tmp/c.p12", bad, ["-clcerts", "-nokeys"], "/tmp/c.crt")

    def test_malicious_passphrase_does_not_execute_and_still_unlocks(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            marker = directory / "pwned"
            passphrase = "x; touch %s #" % marker
            key = directory / "key.pem"
            cert = directory / "cert.pem"
            p12 = directory / "client.p12"
            subprocess.run(
                ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                 "-keyout", str(key), "-out", str(cert), "-days", "1",
                 "-subj", "/CN=bromure-ikev2-test"],
                check=True, capture_output=True)
            # argv, not a shell: the passphrase is one argument to -passout.
            subprocess.run(
                ["openssl", "pkcs12", "-export", "-out", str(p12),
                 "-inkey", str(key), "-in", str(cert),
                 "-passout", "pass:%s" % passphrase],
                check=True, capture_output=True)

            calls = []
            real_run = subprocess.run

            def spy(argv, **kwargs):
                calls.append((argv, kwargs))
                return real_run(argv, **kwargs)

            swanctl = directory / "swanctl"
            state = directory / "state"
            with mock.patch.object(config.subprocess, "run", spy):
                config.write_ikev2_config({
                    "ikev2Server": "vpn.example",
                    "ikev2RemoteID": "vpn.example",
                    "ikev2AuthMethod": "certificate",
                    "ikev2ClientCert": base64.b64encode(p12.read_bytes()).decode(),
                    "ikev2CertPassphrase": passphrase,
                    "ikev2UseDNS": False,
                }, swanctl_dir=str(swanctl), state_dir=str(state))

            self.assertFalse(marker.exists(),
                             "passphrase was executed as a shell command")
            self.assertFalse((state / "client.p12").exists())
            written_cert = (swanctl / "x509" / "client.crt").read_text()
            written_key = (swanctl / "private" / "client.key").read_text()
            self.assertIn("BEGIN CERTIFICATE", written_cert)
            self.assertIn("PRIVATE KEY", written_key)
            # pkcs12 prints bag attributes ahead of the same PEM we exported.
            self.assertIn(cert.read_text().strip(), written_cert)
            key_mode = stat.S_IMODE((swanctl / "private" / "client.key").stat().st_mode)
            self.assertEqual(key_mode, 0o600)
            self.assertTrue(calls, "openssl was not invoked")
            for argv, kwargs in calls:
                self.assertIsInstance(argv, list)
                self.assertNotEqual(kwargs.get("shell"), True)
                self.assertNotIn(passphrase, argv)
                self.assertNotIn(passphrase, " ".join(str(part) for part in argv))
                self.assertEqual(kwargs.get("input"), (passphrase + "\n").encode())
            conf = (swanctl / "conf.d" / "bromure.conf").read_text()
            script = (swanctl / "updown.sh").read_text()
            self.assertNotIn(passphrase, conf)
            self.assertNotIn(passphrase, script)
            self.assertNotIn("-passin pass:", script)
            self.assertNotIn("-passin pass:", conf)

    def test_proxy_password_is_data_not_a_shell_command(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            marker = directory / "pwned"
            password = "x; touch %s # $(touch %s) `touch %s`" % (
                marker, marker.with_suffix(".cmd"), marker.with_suffix(".bt"))
            username = "user); touch %s #" % marker.with_suffix(".user")
            swanctl = directory / "swanctl"
            state = directory / "state"
            config.write_ikev2_config({
                "ikev2Server": "vpn.example",
                "ikev2RemoteID": "vpn.example",
                "ikev2AuthMethod": "eap",
                "ikev2Username": "alice",
                "ikev2Password": "s3cret",  # ggignore: test fixture
                "ikev2UseDNS": True,
                "ikev2ProxyHost": "proxy.example",
                "ikev2ProxyPort": 8080,
                "ikev2ProxyUsername": username,
                "ikev2ProxyPassword": password,
            }, swanctl_dir=str(swanctl), state_dir=str(state))

            snippet_path = state / "ikev2-squid-peer.conf"
            snippet = snippet_path.read_text()
            self.assertEqual(
                snippet,
                "cache_peer proxy.example parent 8080 0 no-query default "
                "login=%s:%s\nnever_direct allow all\n" % (username, password))
            self.assertEqual(stat.S_IMODE(snippet_path.stat().st_mode), 0o600)
            self.assertFalse((state / "ikev2-proxy.conf").exists())

            script = (swanctl / "updown.sh").read_text()
            self.assertNotIn("$PUSER", script)
            self.assertNotIn("$PPASS", script)
            self.assertNotIn("$PHOST", script)
            self.assertNotIn(password, script)
            self.assertNotIn(username, script)
            self.assertIn("cat \"$PROXY_SNIPPET\"", script)
            subprocess.run(["sh", "-n", str(swanctl / "updown.sh")], check=True)

            start = script.index("# BEGIN ikev2-proxy-apply\n")
            end = script.index("# END ikev2-proxy-apply")
            block = script[start:end]
            squid = directory / "squid.conf"
            squid.write_text(
                "http_port 3128\n"
                "cache_peer old.example parent 9 0\n"
                "never_direct allow all\n"
                "acl localnet src 10.0.0.0/8\n")
            env = os.environ.copy()
            env["IKEV2_SQUID_CONF"] = str(squid)
            # Exercise the baked-in snippet path, not an override.
            env.pop("IKEV2_PROXY_SNIPPET", None)
            result = subprocess.run(
                ["sh", "-c", block], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(marker.exists())
            self.assertFalse(marker.with_suffix(".cmd").exists())
            self.assertFalse(marker.with_suffix(".bt").exists())
            self.assertFalse(marker.with_suffix(".user").exists())
            body = squid.read_text()
            self.assertNotIn("old.example", body)
            self.assertEqual(body.count("cache_peer "), 1)
            self.assertIn(
                "cache_peer proxy.example parent 8080 0 no-query default "
                "login=%s:%s\n" % (username, password),
                body)
            self.assertIn("never_direct allow all\n", body)
            self.assertIn("acl localnet src 10.0.0.0/8\n", body)

    def test_proxy_newline_is_refused(self):
        self.assertIsNone(config.ikev2_squid_peer_snippet(
            "proxy.example", 8080, "user", "a\nb"))
        self.assertIsNone(config.ikev2_squid_peer_snippet(
            "proxy.example\nhttp_access allow all", 8080, "", ""))
        self.assertIsNone(config.ikev2_squid_peer_snippet(
            "proxy.example", "8080; id", "user", "secret"))
        self.assertIsNone(config.ikev2_squid_peer_snippet(
            "proxy.example", True, "user", "secret"))
        plain = config.ikev2_squid_peer_snippet("proxy.example", "443", "", "")
        self.assertEqual(
            plain,
            "cache_peer proxy.example parent 443 0 no-query default\n"
            "never_direct allow all\n")

        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            swanctl = directory / "swanctl"
            state = directory / "state"
            config.write_ikev2_config({
                "ikev2Server": "vpn.example",
                "ikev2AuthMethod": "eap",
                "ikev2Username": "alice",
                "ikev2Password": "s3cret",  # ggignore: test fixture
                "ikev2ProxyHost": "proxy.example",
                "ikev2ProxyPort": 8080,
                "ikev2ProxyUsername": "user",
                "ikev2ProxyPassword": "a\nb",
            }, swanctl_dir=str(swanctl), state_dir=str(state))
            self.assertFalse((state / "ikev2-squid-peer.conf").exists())
            self.assertTrue((swanctl / "conf.d" / "bromure.conf").is_file())

    def test_swanctl_quote_round_trips_and_blocks_updown_injection(self):
        samples = [
            "alice",
            "x; id #",
            'a"b',
            "a\\b",
            "foo\\",
            'foo\\"',
            "line1\nline2",
            "has space and } and #",
            "$(id)",
            "`id`",
            "include /tmp/evil",
            "user\n                updown = /bin/sh -c id",
            "tab\there",
            "cr\rhere",
            "mix \" \\ \n $(touch /tmp/pwned)",
        ]
        for sample in samples:
            quoted = config.swanctl_quote(sample)
            value, end = parse_swanctl_string(quoted, 0)
            self.assertEqual(quoted[end:], "", sample)
            self.assertEqual(value, sample)
        with self.assertRaises(ValueError):
            config.swanctl_quote("has\x00nul")

        username = "alice\n                updown = /bin/sh -c id"
        password = 'x\\"; include /tmp/evil\nupdown = /bin/sh -c id'
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            swanctl = directory / "swanctl"
            state = directory / "state"
            config.write_ikev2_config({
                "ikev2Server": "vpn.example\ninclude /tmp/evil",
                "ikev2RemoteID": "id with space } # comment",
                "ikev2AuthMethod": "eap",
                "ikev2Username": username,
                "ikev2Password": password,
                "ikev2UseDNS": False,
            }, swanctl_dir=str(swanctl), state_dir=str(state))
            conf = (swanctl / "conf.d" / "bromure.conf").read_text()
            updown_lines = [
                line.strip() for line in conf.splitlines()
                if line.strip().startswith("updown ")
                or line.strip().startswith("updown=")
            ]
            self.assertEqual(updown_lines, [
                "updown = %s" % (swanctl / "updown.sh")])
            # The injected command survives only as data inside a quoted value.
            values = quoted_values(conf)
            self.assertIn(username, values)
            self.assertIn(password, values)
            self.assertIn("vpn.example\ninclude /tmp/evil", values)
            self.assertIn("id with space } # comment", values)
            self.assertNotIn("\ninclude ", conf.split('secret = ')[0])

    def test_psk_secret_is_quoted(self):
        psk = 'pre"shared\\key\nupdown = /bin/sh -c id'
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            swanctl = directory / "swanctl"
            config.write_ikev2_config({
                "ikev2Server": "10.1.2.3",
                "ikev2AuthMethod": "psk",
                "ikev2PSK": psk,
            }, swanctl_dir=str(swanctl), state_dir=str(directory / "state"))
            conf = (swanctl / "conf.d" / "bromure.conf").read_text()
            self.assertIn(psk, quoted_values(conf))
            updown_lines = [
                line.strip() for line in conf.splitlines()
                if line.strip().startswith("updown ")
                or line.strip().startswith("updown=")
            ]
            self.assertEqual(
                updown_lines, ["updown = %s" % (swanctl / "updown.sh")])

    def test_nul_in_profile_string_writes_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            swanctl = directory / "swanctl"
            config.write_ikev2_config({
                "ikev2Server": "vpn.example",
                "ikev2AuthMethod": "eap",
                "ikev2Username": "alice",
                "ikev2Password": "sec\x00ret",
            }, swanctl_dir=str(swanctl), state_dir=str(directory / "state"))
            self.assertFalse(swanctl.exists())

    def test_guest_scripts_do_not_interpolate_passphrases_into_shell(self):
        offenders = []
        for path in SCRIPTS.rglob("*"):
            if path.suffix not in {".py", ".sh"}:
                continue
            text = path.read_text(errors="replace")
            if "-passin pass:" in text or "login=$PUSER:$PPASS" in text:
                offenders.append(str(path.relative_to(ROOT)))
        self.assertEqual(offenders, [])


if __name__ == "__main__":
    unittest.main()
