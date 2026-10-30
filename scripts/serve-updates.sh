#!/bin/bash
# Serves the generated updates/ directory for local Sparkle testing.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${1:-8787}"
echo "serving $ROOT/updates on http://127.0.0.1:$PORT/appcast.xml"
exec python3 -m http.server "$PORT" --directory "$ROOT/updates"
