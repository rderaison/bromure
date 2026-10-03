#!/usr/bin/env python3
"""Private diagnostic: compare TLS through Squid, routing SOCKS, and direct.

Run inside the private guest as root (not Squid UID). Does not change routing
or browser settings. Direct/SOCKS probes are diagnostics, NOT proxy acceptance.
No credentials, cookies, body, or certificate contents are printed.
"""
import argparse
import ipaddress
import json
import re
import signal
import socket
import ssl
import struct
import time


def expired(*_):
    raise TimeoutError('probe wall deadline')


def exact(sock, count):
    result = b''
    while len(result) < count:
        chunk = sock.recv(count-len(result))
        if not chunk:
            raise ConnectionError('EOF while reading protocol reply')
        result += chunk
    return result


def header(sock):
    data = b''
    while not data.endswith(b'\r\n\r\n'):
        data += exact(sock, 1)
        if len(data) > 16384:
            raise ValueError('response header exceeds limit')
    return data.split(b'\r\n', 1)[0].decode('ascii', 'replace')[:160]


def probe(mode, host, address, context, timeout):
    result = {'mode': mode, 'stage': 'connect', 'ok': False}
    sock = None
    started = time.monotonic()
    signal.setitimer(signal.ITIMER_REAL, timeout)
    try:
        if mode.startswith('squid'):
            sock = socket.create_connection(('127.0.0.1', 3128), timeout=timeout)
            authority = host if mode == 'squid-hostname' else address
            result['stage'] = 'http-connect'
            sock.sendall(('CONNECT ' + authority + ':443 HTTP/1.1\r\nHost: '
                          + authority + ':443\r\n\r\n').encode('ascii'))
            result['connectStatus'] = header(sock)
            if result['connectStatus'].split()[1:2] != ['200']:
                return result
        elif mode == 'routing-socks-numeric':
            sock = socket.create_connection(('127.0.0.1', 40001), timeout=timeout)
            result['stage'] = 'socks-connect'
            sock.sendall(b'\x05\x01\x00')
            if exact(sock, 2) != b'\x05\x00':
                raise ConnectionError('SOCKS greeting rejected')
            sock.sendall(b'\x05\x01\x00\x01' + ipaddress.ip_address(address).packed + struct.pack('!H', 443))
            reply = exact(sock, 4)
            result['socksReplyCode'] = reply[1]
            if reply[:3] != b'\x05\x00\x00':
                raise ConnectionError('SOCKS destination rejected')
            if reply[3] == 1:
                exact(sock, 6)
            elif reply[3] == 4:
                exact(sock, 18)
            elif reply[3] == 3:
                exact(sock, exact(sock, 1)[0]+2)
            else:
                raise ConnectionError('SOCKS invalid address family')
        else:
            sock = socket.create_connection((address, 443), timeout=timeout)
        result['stage'] = 'tls'
        sock = context.wrap_socket(sock, server_hostname=host)
        result['tlsVersion'] = sock.version()
        result['stage'] = 'http-head'
        sock.sendall(('HEAD / HTTP/1.1\r\nHost: ' + host
                      + '\r\nConnection: close\r\n\r\n').encode('ascii'))
        result['httpStatus'] = header(sock)
        result['ok'] = result['httpStatus'].startswith('HTTP/')
        result['stage'] = 'complete'
    except Exception as error:
        result.update(errorType=type(error).__name__, error=str(error)[:256])
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        if sock is not None:
            sock.close()
        result['elapsedMs'] = round((time.monotonic()-started)*1000, 2)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', default='www.slashdot.org')
    parser.add_argument('--address', help='Optional known IPv4, no DNS changes')
    parser.add_argument('--timeout', type=float, default=8)
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9.-]{1,253}', args.host) or not 0 < args.timeout <= 10:
        parser.error('invalid hostname or timeout')
    signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, 5)
    try:
        addresses = sorted({row[4][0] for row in socket.getaddrinfo(args.host, 443, socket.AF_INET, socket.SOCK_STREAM)})
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
    address = str(ipaddress.IPv4Address(args.address)) if args.address else addresses[0]
    context = ssl.create_default_context()
    print(json.dumps({'kind': 'endpoint', 'host': args.host, 'resolvedIPv4': addresses,
                      'selectedIPv4': address, 'certificateVerification': True}), flush=True)
    for mode in ('squid-hostname', 'squid-numeric', 'routing-socks-numeric', 'direct-numeric'):
        print(json.dumps(probe(mode, args.host, address, context, args.timeout)), flush=True)


if __name__ == '__main__':
    main()
