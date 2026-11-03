import os, socket
for key in ('ALL_PROXY', 'HTTP_PROXY', 'HTTPS_PROXY', 'all_proxy', 'http_proxy', 'https_proxy'):
    os.environ.pop(key, None)
try:
    answers = socket.getaddrinfo(@@HOST_PY@@, @@FIXTURE_PORT@@, type=socket.SOCK_STREAM)
except OSError as error:
    resolver = open('/etc/resolv.conf', encoding='utf-8').read()
    routes = open('/proc/net/route', encoding='utf-8').read()
    raise RuntimeError(f'policy DNS lookup failed: {error}\nresolv.conf:\n{resolver}\nroutes:\n{routes}') from error
synthetic = sorted({item[4][0] for item in answers})
assert any(ip.startswith('198.18.') or ip.startswith('198.19.') for ip in synthetic), synthetic
with socket.create_connection((@@HOST_PY@@, @@FIXTURE_PORT@@), timeout=10) as conn:
    conn.sendall(b'probe')
    assert conn.recv(1024) == b'native-tcp-ok:probe'
with socket.create_connection((@@HOST_PY@@, @@TCP_DNS_PORT@@), timeout=10) as conn:
    conn.sendall(b'tcp-53-probe')
    assert conn.recv(1024) == b'native-tcp-ok:tcp-53-probe'

def denied(host, port):
    try:
        with socket.create_connection((host, port), timeout=3) as conn:
            conn.sendall(b'blocked')
            return conn.recv(1024) != b'native-tcp-ok:blocked'
    except OSError:
        return True

assert denied(@@HOST_PY@@, @@WRONG_PORT@@)
assert denied(@@REAL_IP_PY@@, @@FIXTURE_PORT@@)
assert denied(@@REAL_IP_PY@@, @@TRANSPARENT_PORT@@)
print('transparent-tcp-e2e-ok')
