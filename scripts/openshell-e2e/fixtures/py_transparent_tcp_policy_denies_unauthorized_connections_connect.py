def connect(host: str, port: int) -> int:
    import socket

    try:
        with socket.create_connection((host, port), timeout=5):
            return 0
    except OSError as error:
        return error.errno or -1
