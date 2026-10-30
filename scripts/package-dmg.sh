#!/bin/bash
# Builds a distributable DMG (drag-to-Applications) for Lucas.
#
# Usage:
#   ./scripts/package-dmg.sh            # uses build/Lucas.app as-is
#   JAPLOS_VERSION=0.6.0 ./scripts/package-dmg.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/Lucas.app"
if [ ! -d "$APP" ]; then
    echo "missing $APP; run ./scripts/build-app.sh release first" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.0.0)"
OUT="$ROOT/build/Lucas-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/Lucas.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUT"
hdiutil create \
    -volname "Lucas" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$OUT" >/dev/null

# Sign the disk image too when a Developer ID is available.
if [ -n "${LUCAS_SIGN_IDENTITY:-}" ]; then
    codesign --force --sign "$LUCAS_SIGN_IDENTITY" --timestamp "$OUT" >/dev/null
fi

SIZE="$(du -h "$OUT" | awk '{print $1}')"
echo "dmg: $OUT ($SIZE)"
echo "open: open \"$OUT\""
