#!/bin/bash
# Generates updates/Lucas-<version>.html from git commits since the last tag.
# Existing files are never overwritten.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: ./scripts/release-notes.sh <version>" >&2
    exit 1
fi

OUT="$ROOT/updates/Lucas-$VERSION.html"
mkdir -p "$ROOT/updates"
if [ -f "$OUT" ]; then
    echo "release notes already exist: $OUT"
    exit 0
fi

COMMITS=""
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    LAST_TAG="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
    if [ -n "$LAST_TAG" ]; then
        COMMITS="$(git -C "$ROOT" log --no-merges --pretty=format:'%s' "$LAST_TAG..HEAD" 2>/dev/null || true)"
    else
        COMMITS="$(git -C "$ROOT" log --no-merges --pretty=format:'%s' 2>/dev/null || true)"
    fi
fi

OUT="$OUT" COMMITS="$COMMITS" VERSION="$VERSION" python3 - <<'PY'
import html, os
from datetime import date

out = os.environ["OUT"]
version = os.environ["VERSION"]
raw = os.environ.get("COMMITS", "")
lines = [line.strip() for line in raw.splitlines() if line.strip()]
lines = lines[:25]
if not lines:
    lines = ["本次更新包含若干修复与改进。"]

items = "\n".join(f"<li>{html.escape(line)}</li>" for line in lines)
content = f"""<ul>
{items}
</ul>
<p>版本 {html.escape(version)} · {date.today().isoformat()}</p>
"""
open(out, "w").write(content)
print(f"wrote {out} ({len(lines)} items)")
PY
