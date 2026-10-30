#!/usr/bin/env python3
"""Reads a streaming `chat.send` from the clone kernel and validates the events."""
import json
import os
import socket
import struct
import sys
import uuid

SOCKET = os.environ.get("LUCAS_SOCKET", "")
if not SOCKET:
    raise SystemExit("LUCAS_SOCKET is required")

text = sys.argv[1] if len(sys.argv) > 1 else "现在几点了？"


def recv_frame(sock):
    header = sock.recv(4)
    if len(header) < 4:
        raise RuntimeError("connection closed before a complete frame")
    size = struct.unpack(">I", header)[0]
    body = b""
    while len(body) < size:
        chunk = sock.recv(min(65536, size - len(body)))
        if not chunk:
            raise RuntimeError("truncated frame")
        body += chunk
    return json.loads(body)


request = {
    "protocolVersion": "1.0",
    "id": str(uuid.uuid4()).upper(),
    "principal": "local-user",
    "operation": "chat.send",
    "arguments": {"text": text, "stream": True},
}

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(90)
sock.connect(SOCKET)
try:
    body = json.dumps(request).encode()
    sock.sendall(struct.pack(">I", len(body)) + body)

    deltas = []
    tools = []
    final = None
    frames = 0
    while True:
        frame = recv_frame(sock)
        frames += 1
        if "failure" in frame:
            raise SystemExit(f"stream failed: {frame['failure']}")
        result = frame.get("result", {})
        event = result.get("event")
        if event == "delta":
            deltas.append(result.get("text", ""))
        elif event == "tool":
            tools.append(result)
        elif event == "done":
            final = result
            break

    assert frames >= 3, f"expected several frames, got {frames}"
    assert deltas, "no delta frames"
    assert final is not None, "missing done frame"
    assert tools and tools[0]["name"] == "system.time", tools
    assert "现在" in final["text"], final["text"]
    print(f"   frames={frames} deltas={len(deltas)} tool={tools[0]['name']}")
    print(f"   text={final['text']}")
finally:
    sock.close()

print("✅ streaming check passed")
