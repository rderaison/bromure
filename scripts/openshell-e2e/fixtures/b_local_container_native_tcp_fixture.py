import socket, threading
def listen(port):
  s = socket.socket()
  s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
  s.bind(('0.0.0.0', port))
  s.listen()
  return s

def serve(s):
  while True:
    c, _ = s.accept()
    data = c.recv(1024)
    c.sendall(b'native-tcp-ok:' + data)
    c.close()

transparent_listener = listen(@@TRANSPARENT_PORT@@)
tcp_dns_listener = listen(@@TCP_DNS_PORT@@)
fixture_listener = listen(@@FIXTURE_PORT@@)
threading.Thread(target=serve, args=(transparent_listener,), daemon=True).start()
threading.Thread(target=serve, args=(tcp_dns_listener,), daemon=True).start()
serve(fixture_listener)
