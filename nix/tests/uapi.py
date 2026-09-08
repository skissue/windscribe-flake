"""VM-only peer configuration and key-free userspace WireGuard observations."""

import base64
import json
import socket
import sys
from pathlib import Path


def request(device, body):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(5)
        connection.connect(f"/run/amneziawg/{device}.sock")
        connection.sendall((body + "\n\n").encode())
        response = b""
        while not response.endswith(b"\n\n"):
            chunk = connection.recv(4096)
            if not chunk:
                raise RuntimeError("UAPI closed before completing response")
            response += chunk
    values = dict(line.split("=", 1) for line in response.decode().splitlines() if line)
    # Never include the raw response: get includes private and preshared keys.
    assert values.get("errno") == "0", "UAPI request failed"
    return values


if sys.argv[1] == "configure-peer":
    def key(name):
        return base64.b64decode(Path(f"/run/wg-keys/{name}").read_text()).hex()

    request("wg0", "\n".join([
        "set=1", f"private_key={key('peer')}", "listen_port=51820",
        "jc=3", "jmin=40", "jmax=80", "s1=16", "s2=24",
        "h1=100001", "h2=200002", "h3=300003", "h4=400004",
        f"public_key={key('client.pub')}", f"preshared_key={key('psk')}",
        "allowed_ip=10.77.0.2/32",
    ]))
else:
    values = request(sys.argv[1], "get=1")
    fields = ["jc", "jmin", "jmax", "s1", "s2", "h1", "h2", "h3", "h4",
              "last_handshake_time_sec", "rx_bytes", "tx_bytes"]
    print(json.dumps({name: values[name] for name in fields if name in values}))
