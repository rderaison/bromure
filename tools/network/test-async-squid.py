#!/usr/bin/env python3
"""Portable policy/cleanup regressions; kernel redirection lives in netns test."""
import ast
import importlib.util
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch, mock_open

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def load(path):
    spec = importlib.util.spec_from_file_location(path.stem, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


gateway = load(HERE/'async-squid-gateway.py')
launcher = load(HERE/'async-squid-launch.py')
config_path = ROOT/'Sources/SandboxEngine/Resources/vm-setup/scripts/config-agent.py'
config = load(config_path)


class Tests(unittest.TestCase):
    def test_ipv4_only_requires_complete_disabled_policy(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.assertFalse(launcher.ipv6_disabled(root))
            for name in ('all', 'default', 'lo', 'eth0'):
                (root/name).mkdir()
                (root/name/'disable_ipv6').write_text('1\n')
            self.assertTrue(launcher.ipv6_disabled(root))
            for name in ('all', 'default', 'lo', 'eth0'):
                value = root/name/'disable_ipv6'
                value.write_text('0\n')
                self.assertFalse(launcher.ipv6_disabled(root))
                value.write_text('1\n')
            (root/'wg0').mkdir()
            self.assertFalse(launcher.ipv6_disabled(root))
            (root/'wg0/disable_ipv6').write_text('1\n')
            self.assertTrue(launcher.ipv6_disabled(root))

    def test_opt_in_is_explicit_and_missing_candidate_fails_closed(self):
        legacy = ['proxychains4', '-q', '-f', '/etc/proxychains/proxychains.conf',
                  'squid', '-N', '-f', '/etc/squid/squid.conf']
        self.assertEqual(config.squid_launch_command('quiet'), legacy)
        self.assertFalse(launcher.opted_in('quiet'))
        for suffix in ('0', '', 'yes', '1 bromure.experimental_async_squid=1'):
            cmdline = 'bromure.experimental_async_squid=' + suffix
            with self.assertRaises(ValueError):
                config.squid_launch_command(cmdline)
            with self.assertRaises(ValueError):
                launcher.opted_in(cmdline)
        cmdline = 'quiet bromure.experimental_async_squid=1'
        self.assertTrue(launcher.opted_in(cmdline))
        with patch.object(config.os.path, 'isfile', return_value=False):
            with self.assertRaises(RuntimeError):
                config.squid_launch_command(cmdline)
        with patch.object(config.os.path, 'isfile', return_value=True), patch.object(config.os, 'access', return_value=False):
            with self.assertRaises(RuntimeError):
                config.squid_launch_command(cmdline)
        with patch.object(config.os.path, 'isfile', return_value=True), patch.object(config.os, 'access', return_value=True):
            self.assertEqual(config.squid_launch_command(cmdline), ['/usr/local/bin/async-squid-launch.py'])

    def test_external_proxy_never_launches_internal_candidate(self):
        # Execute the actual service-selection AST, so moving the candidate out
        # of the external-proxy guard would fail this regression.
        tree = ast.parse(config_path.read_text())
        block = next(node for node in ast.walk(tree) if isinstance(node, ast.If)
                     and 'squid_command' in ast.unparse(node)
                     and ast.unparse(node.test) == 'not has_custom_proxy')
        source = compile(ast.Module(body=[block], type_ignores=[]), str(config_path), 'exec')
        for custom in (True, False):
            launch = Mock(return_value=['candidate'])
            process = Mock()
            with patch('builtins.open', mock_open(read_data='bromure.experimental_async_squid=1')):
                exec(source, dict(has_custom_proxy=custom, subprocess=process, squid_launch_command=launch))
            self.assertEqual(launch.call_count, 0 if custom else 1)
            self.assertEqual(process.Popen.call_count, 0 if custom else 2)

    def test_partial_rule_install_only_removes_owned_rules(self):
        for fail_at in range(1, 7):
            calls = []
            def run(argv, **kwargs):
                calls.append(argv)
                if len(calls) == fail_at:
                    raise subprocess.CalledProcessError(1, argv)
            rules = launcher.RedirectRules(123, runner=run)
            with self.assertRaises(subprocess.CalledProcessError):
                rules.install()
            owned, jumps = list(rules.owned), list(rules.jumps)
            first_cleanup = len(calls)
            rules.remove()
            cleanup = calls[first_cleanup:]
            self.assertEqual([row[0] for row in cleanup if '-D' in row], list(reversed(jumps)))
            self.assertEqual([row[0] for row in cleanup if '-X' in row], list(reversed(owned)))
            if fail_at == 1:
                self.assertEqual(cleanup, [])  # pre-existing chain never flushed

    def test_redirect_has_no_loopback_exclusion(self):
        calls = []
        rules = launcher.RedirectRules(123, runner=lambda argv, **kw: calls.append(argv))
        rules.install()
        for family in ('iptables', 'ip6tables'):
            jump = next(row for row in calls if row[0] == family and '-I' in row)
            self.assertEqual(jump[5:], ['-I', 'OUTPUT', '1', '-p', 'tcp', '-m', 'owner',
                                      '--uid-owner', '123', '-j', launcher.CHAIN])
        self.assertTrue(all('-d' not in row and '!' not in row for row in calls))

    def test_original_destination_rejects_ambiguous_or_recursive_address(self):
        def original(address, port=443, scope=0, family=None):
            af = socket.AF_INET6 if ':' in address else socket.AF_INET
            raw = struct.pack('=H', family or af) + struct.pack('!H', port)
            if af == socket.AF_INET:
                raw += socket.inet_pton(af, address) + bytes(8)
            else:
                raw += bytes(4) + socket.inet_pton(af, address) + struct.pack('=I', scope)
            return gateway.original_destination(Mock(family=af, getsockopt=Mock(return_value=raw)), 40002)
        for address in ('127.0.0.1', '::1', '198.18.0.1', '2001:db8::1'):
            self.assertEqual(str(original(address)[0]), address)
        for address, port, scope in [('127.0.0.1', 40002, 0), ('::1', 40002, 0),
                                     ('0.0.0.0', 443, 0), ('::', 443, 0), ('224.0.0.1', 443, 0),
                                     ('ff02::1', 443, 0), ('fe80::1', 443, 0),
                                     ('2001:db8::1', 443, 2), ('198.18.0.1', 0, 0)]:
            with self.assertRaises(ValueError):
                original(address, port, scope)
        with self.assertRaises(ValueError):
            original('198.18.0.1', family=socket.AF_INET6)


if __name__ == '__main__':
    unittest.main()
