#!/bin/bash
# Health-check the Sparkle update feed.
#
#   ./scripts/check-updates.sh             # version + signature presence
#   ./scripts/check-updates.sh 0.5.3       # also assert the latest version
#   LUCAS_CHECK_DEEP=1 ./scripts/check-updates.sh   # download zip and verify EdDSA
#   LUCAS_CHECK_RESOLVE=43.132.224.242 ./scripts/check-updates.sh  # bypass local DNS
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED="${1:-}"
FEED="${LUCAS_FEED_URL:-https://updates.okcue.app/lucas/appcast.xml}"

CURL_ARGS=(--fail --silent --show-error --max-time 20)
if [ -n "${LUCAS_CHECK_RESOLVE:-}" ]; then
    CURL_ARGS+=(--resolve "updates.okcue.app:443:${LUCAS_CHECK_RESOLVE}")
fi

XML="$(curl "${CURL_ARGS[@]}" "$FEED")"

export FEED_XML="$XML"
export EXPECTED_VERSION="$EXPECTED"
export PUBLIC_KEY_FILE="$ROOT/Config/sparkle_public_key.txt"
export DEEP="${LUCAS_CHECK_DEEP:-0}"
export RESOLVE_IP="${LUCAS_CHECK_RESOLVE:-}"

python3 - <<'PY'
import base64, os, re, sys, urllib.request

xml = os.environ["FEED_XML"]
expected = os.environ.get("EXPECTED_VERSION", "")
deep = os.environ.get("DEEP") == "1"

items = re.findall(r"<item>(.*?)</item>", xml, re.S)
candidates = []
for item in items:
    build_match = re.search(r"<sparkle:version>(\d+)</sparkle:version>", item)
    short_match = re.search(r"<sparkle:shortVersionString>([^<]+)</sparkle:shortVersionString>", item)
    url_match = re.search(r'<enclosure[^>]*url="([^"]+)"', item)
    sig_match = re.search(r'sparkle:edSignature="([^"]+)"', item)
    if not build_match or not url_match or not sig_match:
        continue
    candidates.append({
        "build": int(build_match.group(1)),
        "version": short_match.group(1) if short_match else build_match.group(1),
        "url": url_match.group(1),
        "signature": sig_match.group(1),
    })

if not candidates:
    print("FAIL: appcast has no usable item")
    sys.exit(1)

latest = max(candidates, key=lambda item: item["build"])
latest_build = latest["build"]
latest_version = latest["version"]
print(f"latest:    {latest_version} ({latest_build})")
print(f"url:       {latest['url']}")
print("signature: present")

if expected and latest_version != expected:
    print(f"FAIL: expected {expected}, feed has {latest_version}")
    sys.exit(1)

if deep:
    import subprocess, tempfile
    public = base64.b64decode(open(os.environ["PUBLIC_KEY_FILE"]).read().strip())
    with tempfile.NamedTemporaryFile(suffix=".zip", delete=False) as tmp:
        target = tmp.name
    cmd = ["curl", "-fsSL", "--max-time", "120"]
    resolve = os.environ.get("RESOLVE_IP", "")
    if resolve:
        cmd += ["--resolve", f"updates.okcue.app:443:{resolve}"]
    cmd += [latest["url"], "-o", target]
    subprocess.run(cmd, check=True)
    payload = open(target, "rb").read()
    os.unlink(target)
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    Ed25519PublicKey.from_public_bytes(public).verify(base64.b64decode(latest["signature"]), payload)
    print(f"zip:       {len(payload)} bytes, EdDSA verified")

print("result:    OK")
PY
