#!/usr/bin/env python3
"""Verifies that closing a streaming socket stops the daemon's work promptly.

The mock model answers `SLOW_TOOL` with 20 slow text frames and *then* a
`system.time` tool call. Because the tool call only arrives after the client
has hung up, a new `tool_invocations` row proves the daemon kept working for a
turn nobody is listening to — which is exactly what this check must rule out.
"""
import json
import os
import socket
import struct
import time
import uuid

SOCKET = os.environ["LUCAS_SOCKET"]
STORE = os.environ.get("LUCAS_STORE") or os.path.join(os.path.dirname(SOCKET), "kernel.sqlite3")


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


def query(sql):
    import sqlite3

    con = sqlite3.connect(f"file:{STORE}?mode=ro", uri=True)
    try:
        return con.execute(sql).fetchall()
    finally:
        con.close()


def tool_rows():
    return query("SELECT COUNT(*) FROM tool_invocations")[0][0]


def latest_run():
    rows = query("SELECT id, state, record_json FROM runs ORDER BY updated_at DESC LIMIT 1")
    return rows[0] if rows else None


slow = connect()
send(slow, "chat.send", {"text": "SLOW_TOOL 慢慢说，然后调个工具", "stream": True})
frames = 0
for _ in range(3):
    frame = recv_frame(slow)
    frames += 1
    assert "result" in frame, frame
print(f"   received {frames} delta frames, closing socket")

before = tool_rows()
slow.close()

# The daemon must cancel the turn and not record more tool rows after the socket closes.
time.sleep(5)
after = tool_rows()
assert after == before, f"tool_invocations grew after stop: {before} -> {after}"
print(f"   tool_invocations stable at {after}")

run = latest_run()
assert run is not None, "no run recorded for the cancelled turn"
run_id, state, record_json = run
record = json.loads(record_json or "{}")
assert state == "failed", f"run {run_id} state={state}, expected failed"
assert record.get("error") == "cancelled", f"run {run_id} record={record}"
print(f"   run {run_id[:8]} state=failed error=cancelled")

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
