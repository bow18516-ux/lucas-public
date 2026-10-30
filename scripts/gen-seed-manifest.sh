#!/bin/bash
# Regenerates Sources/JaplosRuntime/Resources/SeedManifest.json.
#
# The manifest maps a resource-relative path (e.g. "Prompts/core/identity.md")
# to every sha256 the file has ever had in git history. SeededOverride uses it
# to tell "this is an untouched copy of an older release" apart from "the user
# edited this file": a copy without a .seed-sha256 sidecar whose hash is in the
# manifest is refreshed, anything else is kept.
#
#   ./scripts/gen-seed-manifest.sh          rewrite the manifest
#   ./scripts/gen-seed-manifest.sh --check  exit 1 if the manifest is stale
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="Sources/JaplosRuntime/Resources/SeedManifest.json"
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

RESOURCE_PREFIX="Sources/JaplosRuntime/Resources/"
SOURCES=(
    "Sources/JaplosRuntime/Resources/Prompts"
    "Sources/JaplosRuntime/Resources/Injection/scenes.json"
)

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

python3 - "$tmp" <<'PY'
import hashlib
import json
import subprocess
import sys

out_path = sys.argv[1]
prefix = "Sources/JaplosRuntime/Resources/"
sources = [
    "Sources/JaplosRuntime/Resources/Prompts",
    "Sources/JaplosRuntime/Resources/Injection/scenes.json",
]


def run(*args):
    return subprocess.run(args, check=True, capture_output=True).stdout


commits = run("git", "log", "--format=%H", "--", *sources).decode().split()
commits = [c for c in commits if c]
if not commits:
    sys.exit("no history found for the prompt resources")

entries = {}
for commit in commits:
    listed = run("git", "ls-tree", "-r", "--name-only", commit, "--", *sources).decode().splitlines()
    for path in listed:
        if not path.startswith(prefix):
            continue
        key = path[len(prefix):]
        blob = run("git", "show", "%s:%s" % (commit, path))
        digest = hashlib.sha256(blob).hexdigest()
        entries.setdefault(key, set()).add(digest)

# The working tree may already carry content that no commit has yet; a release
# cut from a dirty tree must not treat it as a "historical" version.
status = run("git", "status", "--porcelain", "--", *sources).decode().strip()
if status:
    for line in status.splitlines():
        path = line[3:].split(" -> ")[-1].strip()
        if path.startswith(prefix):
            with open(path, "rb") as handle:
                entries.setdefault(path[len(prefix):], set()).add(
                    hashlib.sha256(handle.read()).hexdigest()
                )

manifest = {key: sorted(values) for key, values in sorted(entries.items())}
with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, ensure_ascii=False, indent=2, sort_keys=True)
    handle.write("\n")
print("wrote %d entries to %s" % (len(manifest), out_path))
PY

if [ "$CHECK" = "1" ]; then
    if ! diff -q "$tmp" "$OUT" >/dev/null 2>&1; then
        echo "SeedManifest.json is stale: run ./scripts/gen-seed-manifest.sh and commit the result." >&2
        exit 1
    fi
    echo "SeedManifest.json is up to date."
else
    mv "$tmp" "$OUT"
    trap - EXIT
fi
