#!/usr/bin/env python3
"""C7: stopping a turn while an approval is pending must not stall the server.

The client disconnects (here: by sending a frame the server cannot decode)
while `system.command.shell.execute` is waiting for approval. The server must
tear the connection down promptly instead of sitting through a fixed timeout,
and the tool must never run.
"""
import json
import os
import socket
import sqlite3
import struct
import time
import uuid

SOCKET = os.environ["LUCAS_SOCKET"]
STORE = os.environ.get("LUCAS_STORE") or os.path.join(os.path.dirname(SOCKET), "kernel.sqlite3")


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


def tool_rows():
    con = sqlite3.connect(f"file:{STORE}?mode=ro", uri=True)
    try:
        return con.execute("SELECT COUNT(*) FROM tool_invocations").fetchone()[0]
    finally:
        con.close()


sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(30)
sock.connect(SOCKET)

send(sock, "chat.send", {"text": "APPROVE 跑个命令", "stream": True})
approval = None
while approval is None:
    frame = recv_frame(sock)
    if frame is None:
        raise SystemExit("stream closed before the approval event")
    if "failure" in frame:
        raise SystemExit(f"stream failed: {frame['failure']}")
    result = frame.get("result", {})
    if result.get("event") == "approval":
        approval = result
print(f"   approval pending for {approval['name']}")

before = tool_rows()
# Not a valid KernelRequest: the server takes its "client went away" path.
sock.sendall(struct.pack(">I", 9) + b"not json!")

started = time.time()
closed = False
while time.time() - started < 10:
    if recv_frame(sock) is None:
        closed = True
        break
elapsed = time.time() - started
sock.close()

assert closed, "server never closed the connection"
assert elapsed < 1.5, f"server took {elapsed:.2f}s to drop a pending approval (expected < 1.5s)"

time.sleep(0.5)
after = tool_rows()
assert after == before, f"the pending tool ran anyway: {before} -> {after}"
print(f"   connection closed in {elapsed:.2f}s, tool_invocations stable at {after}")
print("✅ pending-approval stop check passed")
