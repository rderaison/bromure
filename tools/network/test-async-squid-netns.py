#!/usr/bin/env python3
"""Run ONLY inside sudo unshare --net --mount-proc --pid --fork.

Actual IPv4/IPv6 REDIRECT and numeric SOCKS packets, with bounded fake upstream.
No external network: synthetic addresses are assigned only to namespace lo.
"""
import asyncio
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import shutil
import tempfile
import time

HERE = Path(__file__).resolve().parent
UID = 32001

def load(name):
    spec = importlib.util.spec_from_file_location(name, HERE/(name+'.py'))
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module

gateway_module = load('async-squid-gateway')
launcher = load('async-squid-launch')
CLIENT = '''import socket,sys
s=socket.create_connection((sys.argv[1],int(sys.argv[2])),timeout=3)
data=bytes(range(256))*int(sys.argv[3]);s.sendall(data);s.shutdown(socket.SHUT_WR)
out=b''
while True:
 p=s.recv(65536)
 if not p:break
 out+=p
assert out==b'reply:'+data,(len(out),len(data))
print('CLIENT_PASS',len(out))
'''

async def client(host, port, size=1, success=True):
    p=await asyncio.create_subprocess_exec(sys.executable,'-c',CLIENT,host,str(port),str(size),
        user=UID,group=UID,extra_groups=[],stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE)
    try:
        out,err=await asyncio.wait_for(p.communicate(),5)
        assert (p.returncode==0)==success,(p.returncode,out,err)
        return out.decode().strip()
    finally:
        if p.returncode is None: p.kill();await p.wait()

class Fixture:
    def __init__(self, http=False):
        self.http=http
        self.pending=asyncio.Event();self.release=asyncio.Event();self.requests=[];self.direct=0
        self.tasks=set();self.errors=[]
    async def socks(self,r,w):
        task=asyncio.current_task();self.tasks.add(task)
        try:
            assert await r.readexactly(3)==b'\x05\x01\x00'
            # Deliberately fragmented replies exercise exact-read handling.
            w.write(b'\x05');await w.drain();await asyncio.sleep(.001)
            w.write(b'\x00');await w.drain()
            head=await r.readexactly(4);assert head[:3]==b'\x05\x01\x00'
            assert head[3] in (1,4),head
            raw=await r.readexactly(4 if head[3]==1 else 16)
            address=str(ipaddress.ip_address(raw));port=struct.unpack('!H',await r.readexactly(2))[0]
            self.requests.append((address,port))
            if port==18081:
                self.pending.set();await asyncio.wait_for(self.release.wait(),5)
            w.write(b'\x05\x00\x00\x04'+bytes(18));await w.drain()
            if self.http:
                await asyncio.wait_for(r.readuntil(b'\r\n\r\n'),5)
                w.write(b'HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\nhealthy')
            else:
                data=await asyncio.wait_for(r.read(),5)
                w.write(b'reply:'+data)
            await w.drain()
        except (asyncio.IncompleteReadError, ConnectionResetError, BrokenPipeError):
            pass # failing/cancelled connects need not complete a handshake
        except Exception as error:
            self.errors.append(repr(error))
        finally:
            w.close();self.tasks.discard(task)
    async def trap(self,r,w):
        self.direct+=1
        data=await r.read();w.write(b'reply:'+data);await w.drain();w.close()

async def main():
    assert os.geteuid()==0 and os.getpid()==1,'must run in NEW root PID/network namespaces'
    subprocess.run(['ip','link','set','lo','up'],check=True)
    for address in ('198.18.0.1/32','2001:db8::1/128'):
        subprocess.run(['ip','addr','add',address,'dev','lo'],check=True)
    fixture=Fixture()
    socks=await asyncio.start_server(fixture.socks,'127.0.0.1',40001)
    trap=await asyncio.start_server(fixture.trap,'198.18.0.1',18082)
    g=gateway_module.Gateway(connect_timeout=1,max_connections=8,lifetime=5)
    rules=launcher.RedirectRules(UID)
    results={}
    try:
        await g.start();rules.install()
        slow=asyncio.create_task(client('198.18.0.1',18081))
        await asyncio.wait_for(fixture.pending.wait(),2)
        started=time.monotonic()
        results['ipv4']=await client('198.18.0.1',18082,4096)
        results['ipv6']=await client('2001:db8::1',18082)
        results['loopback']=await client('127.0.0.1',18082)
        results['healthySeconds']=time.monotonic()-started
        assert not slow.done() and fixture.direct==0
        fixture.release.set();results['pending']=await slow
        assert ('198.18.0.1',18082) in fixture.requests and ('2001:db8::1',18082) in fixture.requests
        assert ('127.0.0.1',18082) in fixture.requests
        # Another UID reaches the trap directly; only verified Squid UID redirects.
        r,w=await asyncio.open_connection('198.18.0.1',18082)
        w.write(b'control');w.write_eof();await w.drain()
        assert await r.read()==b'reply:control';w.close()
        assert fixture.direct==1
        results['uidIsolation']=True
        # An ordinary direct connection to gateway cannot supply an arbitrary destination.
        r,w=await asyncio.open_connection('127.0.0.1',40002)
        assert await asyncio.wait_for(r.read(),1)==b'';w.close()
        results['directGatewayRejected']=True
        # Hold every allowed connection. Excess work must be rejected without
        # opening another router connection; a bounded handshake timeout frees
        # all slots and allows a later healthy request.
        fixture.pending.clear();fixture.release.clear()
        before=len(fixture.requests)
        held=[asyncio.create_task(client('198.18.0.1',18081,success=False)) for _ in range(8)]
        deadline=time.monotonic()+.8
        while len(fixture.requests)<before+8 and time.monotonic()<deadline:
            await asyncio.sleep(.005)
        assert len(g.active)==8 and len(fixture.requests)==before+8
        await client('198.18.0.1',18082,success=False)
        assert len(fixture.requests)==before+8 and g.rejected==1
        await asyncio.wait_for(asyncio.gather(*held),2)
        assert not g.active
        fixture.release.set()
        results['afterSaturation']=await client('198.18.0.1',18082)
        results['boundedConnectionsAndDeadline']=True
        # Router unavailable: no fallback to direct origin, trap count unchanged.
        socks.close();await socks.wait_closed()
        await client('198.18.0.1',18082,success=False)
        assert fixture.direct==1
        results['routerUnavailableFailsClosed']=True
        # Gateway unavailable while rules remain: same fail-closed property.
        await g.stop()
        await client('198.18.0.1',18082,success=False)
        assert fixture.direct==1
        results['gatewayUnavailableFailsClosed']=True
        rules.remove();rules.jumps=[];rules.owned=[]
        # Rules are removed exactly; this UID now reaches the local trap normally.
        results['afterCleanup']=await client('198.18.0.1',18082)
        assert fixture.direct==2
        for binary in ('iptables','ip6tables'):
            saved=subprocess.check_output([binary,'-t','nat','-S'],text=True)
            assert launcher.CHAIN not in saved,saved
        results['cleanup']=True
        assert not fixture.errors,fixture.errors
        results['requests']=fixture.requests
        print('BROMURE_ASYNC_SQUID_NETNS_PASS '+json.dumps(results),flush=True)
    finally:
        await g.stop()
        rules.remove()
        socks.close();trap.close();await socks.wait_closed();await trap.wait_closed()
        tasks=list(fixture.tasks)
        for t in tasks:t.cancel()
        await asyncio.gather(*tasks,return_exceptions=True)

class DNS(asyncio.DatagramProtocol):
    def connection_made(self, transport): self.transport=transport
    def datagram_received(self, data, address):
        cursor=12;labels=[]
        try:
            while data[cursor]:
                size=data[cursor];cursor+=1
                labels.append(data[cursor:cursor+size].decode());cursor+=size
            cursor+=1
            kind,klass=struct.unpack('!HH',data[cursor:cursor+4]);end=cursor+4
            name='.'.join(labels)
            assert name in ('allowed.fixture','blocked.fixture') and klass==1
            answer=b''
            if kind==1:
                ip='0.0.0.0' if name=='blocked.fixture' else '198.18.0.1'
                answer=b'\xc0\x0c'+struct.pack('!HHIH',1,1,30,4)+socket.inet_aton(ip)
            response=data[:2]+struct.pack('!HHHHH',0x8180,1,bool(answer),0,0)+data[12:end]+answer
            self.transport.sendto(response,address)
        except (AssertionError,IndexError,UnicodeError):
            pass

async def native_squid(crash=False):
    extracted=Path(os.environ.get('BROMURE_SQUID_TEST_ROOT','/tmp/bromure-network-audit/root'))
    assert (extracted/'usr/sbin/squid').exists(),'extract actual Squid packages first'
    base=Path(tempfile.mkdtemp(prefix='bromure-native-squid-'))
    base.chmod(0o755)
    for name,source in [('squid',extracted/'usr/sbin/squid'),('async-squid-gateway.py',HERE/'async-squid-gateway.py')]:
        shutil.copyfile(source,base/name);(base/name).chmod(0o755)
    config=base/'test.conf'
    config.write_text(f"""http_port 127.0.0.1:3128
visible_hostname async-squid-private-test
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
""")
    dns,_=await asyncio.get_running_loop().create_datagram_endpoint(DNS,local_addr=('127.0.0.1',53))
    fixture=Fixture(http=True)
    socks=await asyncio.start_server(fixture.socks,'127.0.0.1',40001)
    log=open(base/'supervisor.log','wb')
    env=dict(os.environ,LD_LIBRARY_PATH=str(extracted/'usr/lib/aarch64-linux-gnu'))
    proc=await asyncio.create_subprocess_exec(sys.executable,str(HERE/'async-squid-launch.py'),
        '--private-runtime','--squid',str(base/'squid'),'--gateway',str(base/'async-squid-gateway.py'),
        '--config',str(config),'--run-dir',str(base/'run'),env=env,stdout=log,stderr=log)
    async def fetch(target,code=200):
        r,w=await asyncio.open_connection('127.0.0.1',3128)
        try:
            w.write(f'GET http://{target}/test HTTP/1.1\r\nHost: {target}\r\nConnection: close\r\n\r\n'.encode());await w.drain()
            data=await asyncio.wait_for(r.read(),4)
            assert data.split(b'\r\n')[0].split()[1]==str(code).encode(),data[:100]
            if code==200:assert data.endswith(b'healthy'),data[-100:]
        finally:w.close()
    try:
        for _ in range(100):
            if proc.returncode is not None:raise AssertionError((base/'supervisor.log').read_text())
            if 'BROMURE_ASYNC_SQUID_ACTIVE' in (base/'supervisor.log').read_text():break
            await asyncio.sleep(.05)
        else:raise AssertionError('supervisor readiness deadline: '+(base/'supervisor.log').read_text())
        slow=asyncio.create_task(fetch('198.18.0.1:18081'))
        await asyncio.wait_for(fixture.pending.wait(),2)
        start=time.monotonic()
        await fetch('allowed.fixture:18082')
        await fetch('[2001:db8::1]:18082')
        await fetch('blocked.fixture:18082',403)
        elapsed=time.monotonic()-start
        assert not slow.done()
        assert ('198.18.0.1',18082) in fixture.requests and ('2001:db8::1',18082) in fixture.requests
        assert not any(ip=='0.0.0.0' for ip,port in fixture.requests)
        fixture.release.set();await slow
        if crash:
            active=next(line.split(' ',1)[1] for line in (base/'supervisor.log').read_text().splitlines()
                        if line.startswith('BROMURE_ASYNC_SQUID_ACTIVE '))
            identity=json.loads(active)
            os.kill(identity['gatewayPID'],9)
        else:
            proc.terminate()
        await asyncio.wait_for(proc.wait(),8)
        assert (proc.returncode!=0)==crash,(base/'supervisor.log').read_text()
        assert not launcher.processes_for_uid(__import__('pwd').getpwnam('proxy').pw_uid)
        for binary in ('iptables','ip6tables'):
            assert launcher.CHAIN not in subprocess.check_output([binary,'-t','nat','-S'],text=True)
        print('BROMURE_NATIVE_SQUID_GATEWAY_PASS '+json.dumps(dict(healthyAndDNSSeconds=elapsed,
              requests=fixture.requests,dnsSinkholeDenied=True,gatewayCrash=crash,
              producerStoppedBeforeCleanup=True,supervisorExit=proc.returncode,logs=str(base))),flush=True)
    finally:
        fixture.release.set()
        if proc.returncode is None:
            proc.terminate()
            try:await asyncio.wait_for(proc.wait(),8)
            except asyncio.TimeoutError:proc.kill();await proc.wait()
        log.close();dns.close();socks.close();await socks.wait_closed()
        tasks=list(fixture.tasks)
        for t in tasks:t.cancel()
        await asyncio.gather(*tasks,return_exceptions=True)

async def routing_parity():
    # Use the UNMODIFIED production router. Only its flag path, listener and
    # WARP endpoint are private fixtures; no real VPN service is claimed.
    import threading
    router_path=HERE.parents[1]/'Sources/SandboxEngine/Resources/vm-setup/scripts/routing-socks.py'
    spec=importlib.util.spec_from_file_location('production_router',router_path)
    router=importlib.util.module_from_spec(spec);spec.loader.exec_module(router)
    with tempfile.TemporaryDirectory() as tmp:
        router.WARP_FLAG=str(Path(tmp)/'warp-active')
        counts={'direct':0,'warp':0};tasks=set();errors=[]
        async def echo(r,w):
            counts['direct']+=1
            try:
                w.write(await r.readexactly(4));await w.drain()
            finally:w.close()
        async def warp(r,w):
            task=asyncio.current_task();tasks.add(task)
            try:
                assert await r.readexactly(3)==b'\x05\x01\x00'
                w.write(b'\x05\x00');await w.drain()
                head=await r.readexactly(4);assert head[:3]==b'\x05\x01\x00'
                packed=await r.readexactly(4 if head[3]==1 else 16)
                address=str(ipaddress.ip_address(packed))
                port=struct.unpack('!H',await r.readexactly(2))[0]
                assert address in ('127.0.0.1','::1') and port==18083
                counts['warp']+=1
                w.write(b'\x05\x00\x00\x01'+bytes(6));await w.drain()
                w.write(await r.readexactly(4));await w.drain()
            except Exception as error:errors.append(repr(error))
            finally:w.close();tasks.discard(task)
        direct4=await asyncio.start_server(echo,'127.0.0.1',18083)
        direct6=await asyncio.start_server(echo,'::1',18083)
        upstream=await asyncio.start_server(warp,'127.0.0.1',40000)
        listening=socket.socket();listening.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
        listening.bind(('127.0.0.1',40001));listening.listen();listening.settimeout(.1)
        stopped=threading.Event();workers=[]
        def accept():
            while not stopped.is_set():
                try:client,_=listening.accept()
                except socket.timeout:continue
                except OSError:break
                router._conn_semaphore.acquire();client.settimeout(2)
                worker=threading.Thread(target=router.handle_client,args=(client,),daemon=True)
                workers.append(worker);worker.start()
        thread=threading.Thread(target=accept,daemon=True);thread.start()
        gate=gateway_module.Gateway()
        try:
            for use_warp in (False,True,False):
                if use_warp:Path(router.WARP_FLAG).touch()
                else:Path(router.WARP_FLAG).unlink(missing_ok=True)
                for address in ('127.0.0.1','::1'):
                    r,w=await asyncio.wait_for(gate.connect(ipaddress.ip_address(address),18083),2)
                    w.write(b'test');await w.drain()
                    assert await asyncio.wait_for(r.readexactly(4),2)==b'test'
                    w.close();await w.wait_closed()
            assert counts=={'direct':4,'warp':2} and not errors,(counts,errors)
            # An unavailable selected upstream must not fall back to direct.
            upstream.close();await upstream.wait_closed();Path(router.WARP_FLAG).touch()
            try:await asyncio.wait_for(gate.connect(ipaddress.ip_address('127.0.0.1'),18083),2)
            except ConnectionError:pass
            else:raise AssertionError('WARP failure silently fell back')
            assert counts['direct']==4
            print('BROMURE_ROUTING_PARITY_PASS '+json.dumps(dict(counts,warpFailureClosed=True,
                  scope='unmodified router with synthetic WARP endpoint; no live VPN claim')),flush=True)
        finally:
            stopped.set();listening.close();await asyncio.to_thread(thread.join,1)
            for worker in workers:await asyncio.to_thread(worker.join,3)
            for server in (direct4,direct6,upstream):server.close();await server.wait_closed()
            for task in list(tasks):task.cancel()
            await asyncio.gather(*list(tasks),return_exceptions=True)

if __name__=='__main__':
    asyncio.run(main())
    asyncio.run(routing_parity())
    if '--native-squid' in sys.argv:
        asyncio.run(native_squid())
        asyncio.run(native_squid(crash=True))
