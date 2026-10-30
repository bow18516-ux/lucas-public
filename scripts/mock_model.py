#!/usr/bin/env python3
"""A scripted OpenAI-compatible endpoint used to exercise the agent loop offline.

Modes:
  * default          -> calls system.time, then answers with the observed time
  * text contains "APPROVE" -> calls system.command.shell.execute (high risk),
                        which forces the approval flow
  * text contains "SLOW"    -> streams tokens slowly so cancellation can be tested
  * text contains "SLOW_TOOL" -> 20 slow frames, then a system.time tool call, so a
                        cancelled turn would still record a tool invocation if the
                        daemon kept working after the socket closed

Supports blocking JSON and SSE streaming.
"""
import json
import os
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(os.environ.get("MOCK_PORT", "8787"))


def user_text(messages):
    return " ".join(
        (message.get("content") or "") for message in messages if message.get("role") == "user"
    )


def tool_mode(messages):
    for message in messages:
        if message.get("role") == "user" and "APPROVE" in (message.get("content") or ""):
            return "shell"
    return "time"


def tool_result(messages):
    for message in messages:
        if message.get("role") == "tool":
            try:
                return json.loads(message.get("content") or "{}")
            except Exception:
                return {}
    return {}


def final_text(mode, result):
    if mode == "shell":
        output = (result.get("output") or {}).get("stdout") or ""
        if output.strip():
            return f"命令输出：{output.strip()}"
        return f"工具未执行：{result.get('error') or '未知原因'}"
    local = (result.get("output") or {}).get("local", "")
    return f"现在是 {local}（来自 system.time 工具回执）。"


def tool_call(mode):
    if mode == "shell":
        return {
            "id": "call_mock_shell",
            "type": "function",
            "function": {
                "name": "system.command.shell.execute",
                "arguments": json.dumps({"command": "echo approved-ok"}),
            },
        }
    return {
        "id": "call_mock_time",
        "type": "function",
        "function": {"name": "system.time", "arguments": "{}"},
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        payload = json.loads(self.rfile.read(length) or b"{}")
        messages = payload.get("messages", [])
        has_tool_result = any(message.get("role") == "tool" for message in messages)
        mode = tool_mode(messages)
        result = tool_result(messages) if has_tool_result else {}
        text = user_text(messages)
        slow_tool = "SLOW_TOOL" in text
        slow = "SLOW" in text and not slow_tool

        if payload.get("stream"):
            self.stream(has_tool_result, mode, result, slow, slow_tool)
        else:
            self.blocking(payload, has_tool_result, mode, result)

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            body = json.dumps({
                "object": "list",
                "data": [
                    {"id": "mock-model", "object": "model"},
                    {"id": "mock-model-pro", "object": "model"},
                ],
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def blocking(self, payload, has_tool_result, mode, result):
        if has_tool_result:
            reply = {"role": "assistant", "content": final_text(mode, result)}
        else:
            reply = {"role": "assistant", "content": None, "tool_calls": [tool_call(mode)]}
        body = json.dumps(
            {
                "id": "chatcmpl-mock",
                "object": "chat.completion",
                "model": payload.get("model", "mock"),
                "choices": [{"index": 0, "message": reply, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
            }
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def stream(self, has_tool_result, mode, result, slow=False, slow_tool=False):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

        def chunk(delta, finish=None):
            event = {
                "id": "chatcmpl-mock",
                "object": "chat.completion.chunk",
                "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
            }
            self.wfile.write(b"data: " + json.dumps(event).encode() + b"\n\n")
            self.wfile.flush()

        try:
            self._stream_body(has_tool_result, mode, result, slow, slow_tool, chunk)
        except (BrokenPipeError, ConnectionResetError):
            return

    def _stream_body(self, has_tool_result, mode, result, slow, slow_tool, chunk):
        if slow_tool:
            for index in range(20):
                chunk({"content": f"片段{index} "})
                time.sleep(0.1)
            call = tool_call("time")
            chunk(
                {
                    "tool_calls": [
                        {
                            "index": 0,
                            "id": call["id"],
                            "type": "function",
                            "function": call["function"],
                        }
                    ]
                }
            )
            chunk({}, "tool_calls")
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            return

        if slow:
            for index in range(40):
                chunk({"content": f"片段{index} "})
                time.sleep(0.1)
            chunk({}, "stop")
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            return

        if not has_tool_result:
            chunk({"role": "assistant", "content": ""})
            call = tool_call(mode)
            chunk(
                {
                    "tool_calls": [
                        {
                            "index": 0,
                            "id": call["id"],
                            "type": "function",
                            "function": call["function"],
                        }
                    ]
                }
            )
            chunk({}, "tool_calls")
        else:
            for piece in [final_text(mode, result)]:
                chunk({"content": piece})
            chunk({}, "stop")

        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


if __name__ == "__main__":
    print(f"mock model listening on http://127.0.0.1:{PORT}/v1", flush=True)
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
