#!/usr/bin/env python3
"""Minimal client for the Lucas kernel (4-byte BE length + JSON)."""
import json, os, socket, struct, sys, uuid

SOCKET = os.environ.get("LUCAS_SOCKET", os.path.join(os.path.dirname(__file__), "..", "run", "kernel.sock"))
SOCKET = os.path.abspath(SOCKET)


def call(operation, arguments=None, timeout=30.0, principal="local-user"):
    envelope = {
        "protocolVersion": "1.0",
        "id": str(uuid.uuid4()).upper(),
        "principal": principal,
        "operation": operation,
        "arguments": arguments or {},
    }
    body = json.dumps(envelope).encode()
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(SOCKET)
    try:
        s.sendall(struct.pack(">I", len(body)) + body)
        header = s.recv(4)
        if len(header) < 4:
            raise RuntimeError("connection closed before a complete frame")
        size = struct.unpack(">I", header)[0]
        buf = b""
        while len(buf) < size:
            chunk = s.recv(min(65536, size - len(buf)))
            if not chunk:
                raise RuntimeError("truncated frame")
            buf += chunk
        return json.loads(buf)
    finally:
        s.close()


if __name__ == "__main__":
    op = sys.argv[1]
    args = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
    print(json.dumps(call(op, args), ensure_ascii=False, indent=1))
