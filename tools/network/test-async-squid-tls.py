#!/usr/bin/env python3
"""Real verified TLS via native Squid CONNECT, UID REDIRECT and production SOCKS.

Run ONLY: sudo unshare --net --mount-proc --pid --fork python3 THIS_FILE.
No external network, host route mutations, or disabled certificate checks.
"""
import asyncio
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('netns_fixture', HERE/'test-async-squid-netns.py')
fixture = importlib.util.module_from_spec(spec); spec.loader.exec_module(fixture)
BODY = bytes(range(256))*4096


async def main():
    assert os.geteuid() == 0 and os.getpid() == 1, 'requires NEW root network/PID namespaces'
    assert not Path('/tmp/bromure/warp-active').exists(), 'test must not use active host WARP marker'
    extracted = Path(os.environ.get('BROMURE_SQUID_TEST_ROOT', '/tmp/bromure-network-audit/root'))
    assert (extracted/'usr/sbin/squid').exists(), 'extract actual Squid packages first'
    subprocess.run(['ip', 'link', 'set', 'lo', 'up'], check=True, timeout=5)
    subprocess.run(['ip', 'addr', 'add', '198.18.0.1/32', 'dev', 'lo'], check=True, timeout=5)
    base = Path(tempfile.mkdtemp(prefix='bromure-native-tls-'))
    base.chmod(0o755)
    for name, source in [('squid', extracted/'usr/sbin/squid'), ('async-squid-gateway.py', HERE/'async-squid-gateway.py')]:
        shutil.copyfile(source, base/name); (base/name).chmod(0o755)
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                    '-subj', '/CN=allowed.fixture', '-addext', 'subjectAltName=DNS:allowed.fixture',
                    '-keyout', str(base/'key.pem'), '-out', str(base/'cert.pem')],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
    config = base/'test.conf'
    config.write_text(f'''http_port 127.0.0.1:3128
visible_hostname async-squid-tls-test
acl blocked dst 0.0.0.0/32
http_access deny blocked
http_access allow all
cache deny all
cache_mem 8 MB
access_log none
cache_store_log none
cache_log {base}/run/worker/cache.log
netdb_filename none
pinger_enable off
shutdown_lifetime 0 seconds
dns_nameservers 127.0.0.1
unlinkd_program {extracted}/usr/lib/squid/unlinkd
icon_directory {extracted}/usr/share/squid/icons
mime_table {extracted}/usr/share/squid/mime.conf
error_directory {extracted}/usr/share/squid/errors/en
''')
    dns, _ = await asyncio.get_running_loop().create_datagram_endpoint(fixture.DNS, local_addr=('127.0.0.1', 53))
    server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server_context.load_cert_chain(base/'cert.pem', base/'key.pem')
    seen = []; server_errors = []; clients = set()
    async def serve(reader, writer):
        task = asyncio.current_task(); clients.add(task)
        try:
            request = await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 5)
            assert request.startswith(b'GET /fixture HTTP/1.1\r\n'), request[:80]
            seen.append(writer.get_extra_info('ssl_object').version())
            writer.write(b'HTTP/1.1 200 OK\r\nContent-Length: '+str(len(BODY)).encode()+b'\r\n\r\n')
            for offset in range(0, len(BODY), 8191):
                writer.write(BODY[offset:offset+8191]); await writer.drain()
        except Exception as error:
            server_errors.append(repr(error))
        finally:
            writer.close(); clients.discard(task)
    server = await asyncio.start_server(serve, '198.18.0.1', 18443, ssl=server_context)
    router_path = HERE.parents[1]/'Sources/SandboxEngine/Resources/vm-setup/scripts/routing-socks.py'
    router_log = open(base/'router.log', 'wb'); supervisor_log = open(base/'supervisor.log', 'wb')
    router = await asyncio.create_subprocess_exec(sys.executable, str(router_path), stdout=router_log, stderr=router_log)
    proc = None
    env = dict(os.environ, LD_LIBRARY_PATH=str(extracted/'usr/lib/aarch64-linux-gnu'))
    def fetch(version):
        context = ssl.create_default_context(cafile=str(base/'cert.pem'))
        context.minimum_version = context.maximum_version = version
        conn = http.client.HTTPSConnection('127.0.0.1', 3128, timeout=8, context=context)
        conn.set_tunnel('allowed.fixture', 18443)
        try:
            conn.request('GET', '/fixture')
            response = conn.getresponse()
            body = response.read(len(BODY)+1)
            assert response.status == 200 and body == BODY, (response.status, len(body))
            # Complete TLS close_notify before TCP close; http.client.close()
            # alone can reset the peer after an otherwise complete response.
            plain = conn.sock.unwrap()
            plain.close(); conn.sock = None
            return {'version': version.name, 'bytes': len(body), 'sha256': hashlib.sha256(body).hexdigest()}
        finally:
            conn.close()
    try:
        proc = await asyncio.create_subprocess_exec(sys.executable, str(HERE/'async-squid-launch.py'),
                   '--private-runtime', '--diagnostics', '--squid', str(base/'squid'), '--gateway', str(base/'async-squid-gateway.py'),
                   '--config', str(config), '--run-dir', str(base/'run'), env=env,
                   stdout=supervisor_log, stderr=supervisor_log)
        for _ in range(100):
            if proc.returncode is not None:
                raise AssertionError((base/'supervisor.log').read_text())
            if 'BROMURE_ASYNC_SQUID_ACTIVE' in (base/'supervisor.log').read_text():
                break
            await asyncio.sleep(.05)
        else:
            raise AssertionError('supervisor readiness deadline')
        results = []
        for version in (ssl.TLSVersion.TLSv1_2, ssl.TLSVersion.TLSv1_3):
            results.append(await asyncio.wait_for(asyncio.to_thread(fetch, version), 10))
        results.extend(await asyncio.wait_for(asyncio.gather(*[
            asyncio.to_thread(fetch, ssl.TLSVersion.TLSv1_3) for _ in range(8)]), 20))
        assert len(seen) == 10 and not server_errors, (seen, server_errors)
        assert 'connection rejected' not in (base/'supervisor.log').read_text()
        stats_path = base/'run/diagnostics/gateway.json'
        for _ in range(120):
            stats = json.loads(stats_path.read_text())
            if stats['accepted'] == 10:
                break
            await asyncio.sleep(.05)
        else:
            raise AssertionError('periodic diagnostics did not observe transfers')
        assert stats['rejectedCapacity'] == 0 and stats['bytesRead']['router'] >= len(BODY)*10
        assert stats_path.stat().st_mode & 0o077 == 0
        proc.terminate(); await asyncio.wait_for(proc.wait(), 10)
        assert proc.returncode == 0, (base/'supervisor.log').read_text()
        final_stats = json.loads(stats_path.read_text())
        assert final_stats['active'] == 0
        for binary in ('iptables', 'ip6tables'):
            assert fixture.launcher.CHAIN not in subprocess.check_output([binary, '-t', 'nat', '-S'], text=True, timeout=5)
        print('BROMURE_NATIVE_SQUID_TLS_PASS '+json.dumps({
            'scope': 'Isolated local TLS endpoint; actual Squid/gateway/kernel NAT/production router; no external HTTPS claim',
            'results': results, 'serverVersions': seen, 'logs': str(base),
            'certificateVerification': True, 'rulesCleaned': True, 'finalCounters': final_stats,
            'sourceSHA256': {str(p.relative_to(HERE.parents[1])): hashlib.sha256(p.read_bytes()).hexdigest()
                             for p in (Path(__file__), HERE/'async-squid-launch.py', HERE/'async-squid-gateway.py', router_path)}}), flush=True)
    finally:
        for process in (proc, router):
            if process is not None and process.returncode is None:
                process.terminate()
                try: await asyncio.wait_for(process.wait(), 10)
                except asyncio.TimeoutError: process.kill(); await process.wait()
        server.close(); await server.wait_closed(); dns.close()
        for task in list(clients): task.cancel()
        await asyncio.gather(*list(clients), return_exceptions=True)
        router_log.close(); supervisor_log.close()


if __name__ == '__main__':
    asyncio.run(main())
