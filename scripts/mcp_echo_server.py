#!/usr/bin/env python3
"""Minimal stdio MCP server used by the Lucas test-suite.

Newline-delimited JSON-RPC 2.0. Provides two tools: echo and add.
"""
import json
import sys


TOOLS = [
    {
        "name": "echo",
        "description": "Echo the supplied text back.",
        "inputSchema": {
            "type": "object",
            "properties": {"text": {"type": "string"}},
            "required": ["text"],
            "additionalProperties": False,
        },
    },
    {
        "name": "add",
        "description": "Add two numbers.",
        "inputSchema": {
            "type": "object",
            "properties": {"a": {"type": "number"}, "b": {"type": "number"}},
            "required": ["a", "b"],
            "additionalProperties": False,
        },
    },
]


def reply(payload):
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        message = json.loads(line)
    except Exception:
        continue

    method = message.get("method")
    request_id = message.get("id")

    if method == "initialize":
        reply({
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "protocolVersion": "2025-06-18",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "echo-mcp", "version": "1.0.0"},
            },
        })
    elif method in ("notifications/initialized", "notifications/cancelled"):
        continue
    elif method == "tools/list":
        reply({"jsonrpc": "2.0", "id": request_id, "result": {"tools": TOOLS}})
    elif method == "tools/call":
        params = message.get("params") or {}
        name = params.get("name")
        arguments = params.get("arguments") or {}
        if name == "echo":
            text = str(arguments.get("text", ""))
            content = [{"type": "text", "text": f"echo: {text}"}]
        elif name == "add":
            total = float(arguments.get("a", 0)) + float(arguments.get("b", 0))
            content = [{"type": "text", "text": str(total)}]
        else:
            reply({
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32601, "message": f"unknown tool {name}"},
            })
            continue
        reply({"jsonrpc": "2.0", "id": request_id, "result": {"content": content, "isError": False}})
    elif request_id is not None:
        reply({
            "jsonrpc": "2.0",
            "id": request_id,
            "error": {"code": -32601, "message": f"unknown method {method}"},
        })
