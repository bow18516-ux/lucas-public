#!/usr/bin/env python3
"""Verifies that closing a streaming socket stops the daemon's work promptly."""
import json
import os
import socket
import struct
import sys
import time
import uuid

SOCKET = os.environ["LUCAS_SOCKET"]


def connect():
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(30)
    sock.connect(SOCKET)
    return sock


def send(sock, operation, arguments):
    request = {
        "protocolVersion": "1.0",
        "id": str(uuid.uuid4()).upper(),
        "principal": "local-user",
        "operation": operation,
        "arguments": arguments,
    }
    body = json.dumps(request).encode()
    sock.sendall(struct.pack(">I", len(body)) + body)


def recv_frame(sock):
    header = sock.recv(4)
    if len(header) < 4:
        raise RuntimeError("closed")
    size = struct.unpack(">I", header)[0]
    body = b""
    while len(body) < size:
        chunk = sock.recv(min(65536, size - len(body)))
        if not chunk:
            raise RuntimeError("truncated")
        body += chunk
    return json.loads(body)


slow = connect()
send(slow, "chat.send", {"text": "SLOW 慢慢说", "stream": True})
frames = 0
for _ in range(3):
    frame = recv_frame(slow)
    frames += 1
    assert "result" in frame, frame
print(f"   received {frames} delta frames, closing socket")
slow.close()

# Give the daemon a moment to notice the broken pipe, then verify it is healthy.
time.sleep(1.5)
health = connect()
send(health, "kernel.ping", {})
pong = recv_frame(health)
health.close()
assert pong.get("result", {}).get("pong") is True, pong

sessions = connect()
send(sessions, "chat.sessions.list", {"limit": 5})
listed = recv_frame(sessions)
sessions.close()
latest = listed["result"][0]["id"]

history = connect()
send(history, "chat.history", {"sessionID": latest})
turns = recv_frame(history)["result"]
history.close()

assistant = [turn for turn in turns if turn["role"] == "assistant"]
assert not any("片段" in turn["text"] for turn in assistant), "cancelled reply was persisted"
print(f"   daemon healthy after cancel, persisted turns={len(turns)}")
print("✅ cancellation check passed")
