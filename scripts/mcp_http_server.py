#!/usr/bin/env python3
"""Minimal streamable-HTTP MCP server for the Lucas test-suite."""
import json
import os
import sys
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(os.environ.get("MCP_HTTP_PORT", "8799"))
SESSION = uuid.uuid4().hex

TOOLS = [
    {
        "name": "echo",
        "description": "Echo the supplied text back over HTTP.",
        "inputSchema": {
            "type": "object",
            "properties": {"text": {"type": "string"}},
            "required": ["text"],
            "additionalProperties": False,
        },
    },
    {
        "name": "add",
        "description": "Add two numbers over HTTP.",
        "inputSchema": {
            "type": "object",
            "properties": {"a": {"type": "number"}, "b": {"type": "number"}},
            "required": ["a", "b"],
            "additionalProperties": False,
        },
    },
]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        message = json.loads(self.rfile.read(length) or b"{}")
        method = message.get("method")
        request_id = message.get("id")

        if method == "notifications/initialized":
            self.send_response(202)
            self.send_header("Mcp-Session-Id", SESSION)
            self.end_headers()
            return

        result = None
        if method == "initialize":
            result = {
                "protocolVersion": "2025-06-18",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "echo-http", "version": "1.0.0"},
            }
        elif method == "tools/list":
            result = {"tools": TOOLS}
        elif method == "tools/call":
            params = message.get("params") or {}
            name = params.get("name")
            arguments = params.get("arguments") or {}
            if name == "echo":
                result = {"content": [{"type": "text", "text": f"http-echo: {arguments.get('text', '')}"}], "isError": False}
            elif name == "add":
                total = float(arguments.get("a", 0)) + float(arguments.get("b", 0))
                result = {"content": [{"type": "text", "text": str(total)}], "isError": False}
            else:
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Mcp-Session-Id", SESSION)
                body = json.dumps({
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {"code": -32601, "message": f"unknown tool {name}"},
                }).encode()
                self.end_headers()
                self.wfile.write(body)
                return
        else:
            self.send_response(404)
            self.end_headers()
            return

        body = json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Mcp-Session-Id", SESSION)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    print(f"http mcp listening on http://127.0.0.1:{PORT}/mcp", flush=True)
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
