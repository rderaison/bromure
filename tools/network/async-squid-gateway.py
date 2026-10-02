#!/usr/bin/env python3
"""PRIVATE candidate: numeric original-destination TCP -> existing SOCKS router.

Only the opt-in supervisor installs UID-scoped REDIRECT rules. This process has
no direct destination connector and never resolves the destination hostname.
"""
import argparse
import asyncio
import ipaddress
import json
import signal
import socket
import struct
import sys

ORIGINAL_DST = 80
BUFFER = 65536


def original_destination(sock, gateway_port):
    family = sock.family
    if family == socket.AF_INET:
        raw = sock.getsockopt(socket.SOL_IP, ORIGINAL_DST, 16)
        if len(raw) != 16 or struct.unpack_from('=H', raw)[0] != socket.AF_INET:
            raise ValueError('invalid IPv4 original destination')
        address = ipaddress.ip_address(raw[4:8])
    elif family == socket.AF_INET6:
        raw = sock.getsockopt(socket.IPPROTO_IPV6, ORIGINAL_DST, 28)
        if len(raw) != 28 or struct.unpack_from('=H', raw)[0] != socket.AF_INET6:
            raise ValueError('invalid IPv6 original destination')
        address = ipaddress.ip_address(raw[8:24])
        if struct.unpack_from('=I', raw, 24)[0] or address.is_link_local:
            raise ValueError('SOCKS cannot preserve scoped IPv6 destination')
    else:
        raise ValueError('unsupported socket family')
    port = struct.unpack_from('!H', raw, 2)[0]
    if not port or address.is_unspecified or address.is_multicast:
        raise ValueError('invalid original destination')
    if address.is_loopback and port == gateway_port:
        raise ValueError('direct gateway connection or recursion')
    return address, port


class Gateway:
    def __init__(self, port=40002, router_port=40001, max_connections=256,
                 connect_timeout=30, lifetime=86400, ipv4_only=False):
        self.port, self.router_port = port, router_port
        self.max_connections = max_connections
        self.connect_timeout, self.lifetime = connect_timeout, lifetime
        self.ipv4_only = ipv4_only
        self.active = set()
        self.servers = []
        self.accepted = self.rejected = self.failed = 0

    async def connect(self, address, port):
        reader, writer = await asyncio.open_connection('127.0.0.1', self.router_port)
        try:
            writer.write(b'\x05\x01\x00')
            await writer.drain()
            if await reader.readexactly(2) != b'\x05\x00':
                raise ConnectionError('SOCKS authentication rejected')
            atyp = 1 if address.version == 4 else 4
            writer.write(bytes((5, 1, 0, atyp)) + address.packed + struct.pack('!H', port))
            await writer.drain()
            reply = await reader.readexactly(4)
            if reply[:3] != b'\x05\x00\x00':
                raise ConnectionError('SOCKS destination rejected')
            if reply[3] == 1:
                await reader.readexactly(6)
            elif reply[3] == 4:
                await reader.readexactly(18)
            elif reply[3] == 3:
                length = (await reader.readexactly(1))[0]
                if not length:
                    raise ConnectionError('invalid SOCKS reply domain')
                await reader.readexactly(length + 2)
            else:
                raise ConnectionError('invalid SOCKS reply family')
            return reader, writer
        except BaseException:
            writer.close()
            raise

    @staticmethod
    async def pump(reader, writer):
        while True:
            data = await reader.read(BUFFER)
            if not data:
                if writer.can_write_eof():
                    writer.write_eof()
                    await writer.drain()
                return
            writer.write(data)
            await writer.drain()

    async def relay(self, downstream_reader, downstream_writer, upstream_reader, upstream_writer):
        tasks = [asyncio.create_task(self.pump(downstream_reader, upstream_writer)),
                 asyncio.create_task(self.pump(upstream_reader, downstream_writer))]
        try:
            await asyncio.gather(*tasks)
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)

    async def client(self, reader, writer):
        task = asyncio.current_task()
        if len(self.active) >= self.max_connections:
            self.rejected += 1
            writer.close()
            return
        self.active.add(task)
        upstream = None
        try:
            destination = original_destination(writer.get_extra_info('socket'), self.port)
            upstream_reader, upstream = await asyncio.wait_for(self.connect(*destination), self.connect_timeout)
            self.accepted += 1
            await asyncio.wait_for(self.relay(reader, writer, upstream_reader, upstream), self.lifetime)
        except (OSError, ValueError, asyncio.TimeoutError, asyncio.IncompleteReadError) as error:
            self.failed += 1
            # Rate-limit diagnostics: never log credentials or application data.
            if self.failed <= 8 or self.failed % 128 == 0:
                print('async-squid: connection rejected: ' + str(error), file=sys.stderr, flush=True)
        finally:
            if upstream:
                upstream.close()
            writer.close()
            self.active.discard(task)

    async def start(self):
        try:
            families = [(socket.AF_INET, '127.0.0.1')]
            if not self.ipv4_only:
                families.append((socket.AF_INET6, '::1'))
            for family, host in families:
                sock = socket.socket(family, socket.SOCK_STREAM)
                try:
                    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                    if family == socket.AF_INET6:
                        sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                    sock.bind((host, self.port))
                    sock.setblocking(False)
                    self.servers.append(await asyncio.start_server(self.client, sock=sock, limit=BUFFER, backlog=128))
                except BaseException:
                    sock.close()
                    raise
        except BaseException:
            await self.stop()
            raise

    async def stop(self):
        for server in self.servers:
            server.close()
        await asyncio.gather(*(s.wait_closed() for s in self.servers))
        tasks = list(self.active)
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=40002)
    parser.add_argument('--router-port', type=int, default=40001)
    parser.add_argument('--max-connections', type=int, default=256)
    parser.add_argument('--connect-timeout', type=float, default=30)
    parser.add_argument('--lifetime', type=float, default=86400)
    parser.add_argument('--ipv4-only', action='store_true',
                        help='supervisor must verify disabled IPv6 and STILL install IPv6 redirect rules')
    args = parser.parse_args()
    if not (1024 <= args.port <= 65535 and 1 <= args.router_port <= 65535 and args.port != args.router_port
            and 1 <= args.max_connections <= 256 and 0 < args.connect_timeout <= 30 and 0 < args.lifetime <= 86400):
        parser.error('candidate limits exceeded')
    gateway = Gateway(args.port, args.router_port, args.max_connections, args.connect_timeout, args.lifetime,
                      ipv4_only=args.ipv4_only)
    stopped = asyncio.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        asyncio.get_running_loop().add_signal_handler(sig, stopped.set)
    await gateway.start()
    print('BROMURE_ASYNC_SQUID_READY ' + json.dumps(vars(args)), flush=True)
    try:
        await stopped.wait()
    finally:
        await gateway.stop()


if __name__ == '__main__':
    asyncio.run(main())
