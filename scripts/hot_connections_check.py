#!/usr/bin/env python3
"""D3: many slow streaming turns must not starve ordinary requests.

Opens N streaming `chat.send` connections that the mock answers slowly, then
measures `kernel.ping` latency. The server must keep serving short requests
while the streams are in flight.
"""
import json
import os
import socket
import struct
import sys
import time
import uuid

SOCKET = os.environ["LUCAS_SOCKET"]
CONNECTIONS = int(os.environ.get("LUCAS_HOT_CONNECTIONS", "50"))
BUDGET_MS = float(os.environ.get("LUCAS_PING_BUDGET_MS", "200"))


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
        return None
    size = struct.unpack(">I", header)[0]
    body = b""
    while len(body) < size:
        chunk = sock.recv(min(65536, size - len(body)))
        if not chunk:
            return None
        body += chunk
    return json.loads(body)


def ping_latency_ms():
    started = time.time()
    sock = connect()
    send(sock, "kernel.ping", {})
    frame = recv_frame(sock)
    sock.close()
    assert frame and frame.get("result", {}).get("pong") is True, frame
    return (time.time() - started) * 1000


streams = []
for _ in range(CONNECTIONS):
    sock = connect()
    send(sock, "chat.send", {"text": "SLOW 慢慢说", "stream": True})
    streams.append(sock)
print(f"   opened {len(streams)} slow streams")

# Let the turns reach the model before measuring.
time.sleep(0.5)
latencies = []
for _ in range(5):
    latencies.append(ping_latency_ms())
    time.sleep(0.1)

for sock in streams:
    sock.close()

worst = max(latencies)
average = sum(latencies) / len(latencies)
print(f"   ping latency: avg {average:.0f}ms, max {worst:.0f}ms (budget {BUDGET_MS:.0f}ms)")
assert worst < BUDGET_MS, f"kernel.ping took {worst:.0f}ms under {CONNECTIONS} slow streams"
print("✅ hot-connection check passed")
