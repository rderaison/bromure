
import json
import socket

targets = {
    "metadata": ("169.254.169.254", 80),
    "control_plane": ("203.0.113.10", 6443),
    "outside_allowed_ips": ("203.0.113.10", 8080),
}
result = {}
for name, target in targets.items():
    try:
        with socket.create_connection(target, timeout=10):
            result[name] = 0
    except OSError as error:
        result[name] = error.errno
print(json.dumps(result, sort_keys=True))
