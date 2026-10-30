#!/usr/bin/env python3
"""Exercises the high-risk tool approval round-trip.

Usage: approval_check.py allow|deny [shell|mcp]

  shell (default) -> system.command.shell.execute via the "APPROVE" prompt
  mcp             -> mcp.echo.echo via the "MCP_ECHO" prompt, which proves an
                     approved MCP tool actually runs end to end.
"""
import json
import os
import socket
import struct
import sys
import uuid

SOCKET = os.environ["LUCAS_SOCKET"]
decision = sys.argv[1] if len(sys.argv) > 1 else "allow"
assert decision in ("allow", "deny")
mode = sys.argv[2] if len(sys.argv) > 2 else "shell"
assert mode in ("shell", "mcp")

if mode == "mcp":
    prompt = "MCP_ECHO 调一下 echo"
    tool_name = "mcp.echo.echo"
    expected = "echo: smoke"
else:
    prompt = "APPROVE 跑个命令"
    tool_name = "system.command.shell.execute"
    expected = "approved-ok"


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
        raise RuntimeError("connection closed")
    size = struct.unpack(">I", header)[0]
    body = b""
    while len(body) < size:
        chunk = sock.recv(min(65536, size - len(body)))
        if not chunk:
            raise RuntimeError("truncated frame")
        body += chunk
    return json.loads(body)


sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(60)
sock.connect(SOCKET)
try:
    send(sock, "chat.send", {"text": prompt, "stream": True})

    approval = None
    tools = []
    final = None
    while True:
        frame = recv_frame(sock)
        if "failure" in frame:
            raise SystemExit(f"stream failed: {frame['failure']}")
        result = frame.get("result", {})
        event = result.get("event")
        if event == "approval":
            approval = result
            send(sock, "tool.approval", {
                "callID": result["callID"],
                "approved": decision == "allow",
            })
        elif event == "tool":
            tools.append(result)
        elif event == "done":
            final = result
            break

    assert approval is not None, "no approval event"
    assert approval["name"] == tool_name, approval
    assert tools, "no tool event"
    tool = tools[0]

    if decision == "allow":
        assert tool["ok"] is True, tool
        assert expected in final["text"], final["text"]
        print(f"   approved -> tool ok, text={final['text']!r}")
    else:
        assert tool["ok"] is False, tool
        assert "未执行" in final["text"] or "拒绝" in final["text"], final["text"]
        print(f"   denied -> tool blocked, text={final['text']!r}")
finally:
    sock.close()

print(f"✅ approval check ({decision}/{mode}) passed")
