#!/bin/bash
# End-to-end smoke test: daemon + capability RPC + agent loop against a mock model.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WORK="$(mktemp -d)"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
HTTP_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
DAEMON_PID=""
MOCK_PID=""
MCP_HTTP_PID=""

cleanup() {
  [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null || true
  [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null || true
  [ -n "$MCP_HTTP_PID" ] && kill "$MCP_HTTP_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

swift build --disable-sandbox --product lucasd >/dev/null

LUCAS_CLONE_HOME="$WORK" LUCAS_SECRET_BACKEND=file .build/debug/lucasd \
  --socket "$WORK/kernel.sock" --store "$WORK/kernel.sqlite3" >"$WORK/daemon.log" 2>&1 &
DAEMON_PID=$!

MOCK_PORT="$PORT" python3 scripts/mock_model.py >"$WORK/mock.log" 2>&1 &
MOCK_PID=$!

MCP_HTTP_PORT="$HTTP_PORT" python3 scripts/mcp_http_server.py >"$WORK/mcphttp.log" 2>&1 &
MCP_HTTP_PID=$!

for _ in $(seq 1 50); do
  if LUCAS_SOCKET="$WORK/kernel.sock" python3 scripts/kernel_rpc.py kernel.ping '{}' >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

export LUCAS_SOCKET="$WORK/kernel.sock"

echo "1. kernel.status"
python3 scripts/kernel_rpc.py kernel.status '{}' | grep -q '"tools": 15'

echo "2. tool.invoke system.time"
python3 scripts/kernel_rpc.py tool.invoke '{"name":"system.time","arguments":{}}' | grep -q '"ok": true'

echo "3. policy denial for unknown principal"
python3 - "$WORK" <<'PY'
import json, sys
sys.path.insert(0, "scripts")
import kernel_rpc
response = kernel_rpc.call("kernel.status", {}, principal="intruder")
assert response["failure"]["code"] == "permission_denied", response
PY

echo "4. configure mock model"
python3 scripts/kernel_rpc.py configuration.set \
  "{\"path\":\"agents.default.model.connection\",\"value\":{\"baseURL\":\"http://127.0.0.1:$PORT/v1\",\"model\":\"mock\",\"apiKey\":\"test\",\"temperature\":0.2}}" >/dev/null

echo "5. chat.send -> tool call -> final answer"
python3 scripts/kernel_rpc.py chat.send '{"text":"现在几点了？"}' >"$WORK/result.json"
python3 - "$WORK/result.json" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1]))
result = payload.get("result")
assert result is not None, payload
assert result["steps"], "expected at least one tool step"
assert result["steps"][0]["tool"] == "system.time", result["steps"]
assert result["steps"][0]["ok"] is True, result["steps"]
assert "现在" in result["text"], result["text"]
print("   assistant:", result["text"])
PY

echo "6. streaming chat.send"
python3 scripts/stream_check.py "现在几点了？"

echo "7. history persisted"
python3 - "$WORK" <<'PY'
import json, sys
sys.path.insert(0, "scripts")
import kernel_rpc
sessions = kernel_rpc.call("chat.sessions.list", {"limit": 10})["result"]
assert sessions, "no sessions persisted"
history = kernel_rpc.call("chat.history", {"sessionID": sessions[0]["id"]})["result"]
roles = [turn["role"] for turn in history]
assert "user" in roles and "assistant" in roles and "tool" in roles, roles
assert any(turn.get("text", "").startswith("现在是") for turn in history if turn["role"] == "assistant"), "assistant reply not persisted"
print("   turns:", len(history))
PY

echo "8. cancellation stops the turn"
python3 scripts/cancel_check.py

echo "9. dangerous command guard"
python3 scripts/kernel_rpc.py tool.invoke \
  '{"name":"system.command.shell.execute","arguments":{"command":"sudo rm -rf /tmp/nope"}}' \
  | grep -q '"ok": false'

echo "10. high-risk tool approval (allow)"
python3 scripts/approval_check.py allow

echo "11. high-risk tool approval (deny)"
python3 scripts/approval_check.py deny

echo "12. system info tools (window/process/network)"
python3 scripts/kernel_rpc.py tool.invoke '{"name":"system.window.list","arguments":{}}' | grep -q '"ok": true'
python3 scripts/kernel_rpc.py tool.invoke '{"name":"system.process.list","arguments":{"limit":3}}' | grep -q '"ok": true'
python3 scripts/kernel_rpc.py tool.invoke '{"name":"system.network.info","arguments":{}}' | grep -q '"ok": true'

echo "13. PDF generation"
rm -f /tmp/lucas-smoke.pdf
python3 scripts/kernel_rpc.py tool.invoke \
  '{"name":"system.document.pdf.create","arguments":{"text":"Japlos smoke test","path":"/tmp/lucas-smoke.pdf"}}' \
  | grep -q '"ok": true'
test -s /tmp/lucas-smoke.pdf

echo "14. MCP stdio server"
python3 scripts/kernel_rpc.py configuration.set \
  "{\"path\":\"mcp.servers\",\"value\":[{\"id\":\"echo\",\"name\":\"Echo\",\"command\":\"python3\",\"args\":[\"$ROOT/scripts/mcp_echo_server.py\"],\"enabled\":true}]}" >/dev/null
python3 scripts/kernel_rpc.py mcp.refresh '{}' | grep -q '"toolCount": 2'
python3 scripts/kernel_rpc.py tool.invoke '{"name":"mcp.echo.echo","arguments":{"text":"smoke"}}' | grep -q 'echo: smoke'

echo "15. MCP HTTP server"
python3 scripts/kernel_rpc.py configuration.set \
  "{\"path\":\"mcp.servers\",\"value\":[{\"id\":\"echo\",\"name\":\"Echo\",\"command\":\"python3\",\"args\":[\"$ROOT/scripts/mcp_echo_server.py\"],\"enabled\":true},{\"id\":\"http\",\"name\":\"HTTP Echo\",\"url\":\"http://127.0.0.1:$HTTP_PORT/mcp\",\"enabled\":true}]}" >/dev/null
python3 scripts/kernel_rpc.py mcp.refresh '{}' | grep -q '"toolCount": 4'
python3 scripts/kernel_rpc.py tool.invoke '{"name":"mcp.http.echo","arguments":{"text":"smoke"}}' | grep -q 'http-echo: smoke'

echo "16. model catalog"
python3 scripts/kernel_rpc.py model.catalog '{}' | grep -q 'mock-model'

echo "✅ smoke test passed"
