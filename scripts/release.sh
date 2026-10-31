#!/bin/bash
# Builds a signed, notarized release and refreshes the Sparkle appcast.
#
# Required once:
#   Config/sparkle_public_key.txt   (committed)
#   ~/.config/lucas-release/sparkle_ed_key   (private, outside the checkout)
#   Developer ID Application certificate in the login keychain
#   xcrun notarytool store-credentials japlos-notary ...
#
# Environment:
#   LUCAS_SIGN_IDENTITY   "Developer ID Application: Name (TEAMID)"
#   LUCAS_NOTARY_PROFILE  notarytool keychain profile (e.g. japlos-notary)
#   LUCAS_FEED_URL        https://updates.example.com/lucas/appcast.xml
#   LUCAS_DOWNLOAD_PREFIX https://updates.example.com/lucas/
#   LUCAS_DEPLOY_TARGET   user@host:/var/www/updates/lucas/
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: ./scripts/release.sh <version>   e.g. 0.5.0" >&2
    exit 1
fi

FEED_URL="${LUCAS_FEED_URL:-}"
if [ -z "$FEED_URL" ] || [[ "$FEED_URL" == *"example.com"* ]]; then
    echo "refusing to release: LUCAS_FEED_URL must point at the real HTTPS appcast" >&2
    echo "  export LUCAS_FEED_URL=https://your.domain/lucas/appcast.xml" >&2
    exit 1
fi

if [ -z "${LUCAS_SIGN_IDENTITY:-}" ]; then
    echo "refusing to release: LUCAS_SIGN_IDENTITY is not set (Developer ID Application)" >&2
    exit 1
fi

if [ -z "${LUCAS_NOTARY_PROFILE:-}" ] && [ -z "${LUCAS_ALLOW_UNNOTARIZED:-}" ]; then
    echo "refusing to release: LUCAS_NOTARY_PROFILE is not set" >&2
    echo "  set LUCAS_ALLOW_UNNOTARIZED=1 only for a local test build" >&2
    exit 1
fi

# Optional dedicated notary keychain (credentials live there via store-credentials).
# Do not unlock with a password on the command line; unlock the keychain in the
# session first, or use a login-keychain profile.
NOTARY_KEYCHAIN_ARGS=()
if [ -n "${LUCAS_NOTARY_KEYCHAIN:-}" ]; then
    NOTARY_KEYCHAIN_ARGS+=(--keychain "$LUCAS_NOTARY_KEYCHAIN")
fi

BUILD_NUMBER="${LUCAS_BUILD:-$(date +%Y%m%d%H%M)}"

# Publish gate: marketing must not regress vs live appcast; build must rise.
# Skip only for explicit local drills (LUCAS_SKIP_VERSION_GUARD=1).
if [ -z "${LUCAS_SKIP_VERSION_GUARD:-}" ]; then
    echo "version guard: proposed $VERSION ($BUILD_NUMBER) vs live feed…"
    python3 "$ROOT/scripts/version_bump_guard.py" \
        --marketing "$VERSION" \
        --build "$BUILD_NUMBER" \
        --feed "$FEED_URL"
else
    echo "warning: LUCAS_SKIP_VERSION_GUARD=1 — skipping live appcast version gate" >&2
fi

DOWNLOAD_PREFIX="${LUCAS_DOWNLOAD_PREFIX:-${FEED_URL%appcast.xml}}"
UPDATES="$ROOT/updates"
SECRETS_DIR="${LUCAS_RELEASE_SECRETS:-$HOME/.config/lucas-release}"
KEY="$SECRETS_DIR/sparkle_ed_key"
APP="$ROOT/build/Lucas.app"

# The seed manifest tells SeededOverride which prompt files an older release
# copied out; a stale one makes legacy users keep an outdated prompt forever.
if ! ./scripts/gen-seed-manifest.sh --check; then
    echo "refusing to release: regenerate and commit Sources/JaplosRuntime/Resources/SeedManifest.json" >&2
    exit 1
fi

if [ ! -f "$KEY" ]; then
    echo "missing $KEY (Sparkle EdDSA private key)" >&2
    exit 1
fi

export LUCAS_VERSION="$VERSION"
export LUCAS_BUILD="$BUILD_NUMBER"
export LUCAS_FEED_URL="$FEED_URL"
export LUCAS_ENABLE_AUTO_UPDATES=1

./scripts/build-app.sh release

if [ -n "${LUCAS_NOTARY_PROFILE:-}" ]; then
    echo "notarizing…"
    ditto -c -k --keepParent "$APP" "/tmp/Lucas-$VERSION.zip"
    # Credentials live in the login keychain (xcrun notarytool store-credentials),
    # which the user session already unlocked: no password on the command line.
    xcrun notarytool submit "/tmp/Lucas-$VERSION.zip" \
        --keychain-profile "$LUCAS_NOTARY_PROFILE" \
        ${NOTARY_KEYCHAIN_ARGS[@]+"${NOTARY_KEYCHAIN_ARGS[@]}"} --wait

    # Staple a clean extraction of the submitted zip. Stapling the build
    # directory occasionally fails with "Error 73" after repeated rebuilds.
    STAPLE_DIR="$(mktemp -d)"
    ditto -x -k "/tmp/Lucas-$VERSION.zip" "$STAPLE_DIR"
    xcrun stapler staple "$STAPLE_DIR/Lucas.app"
    xcrun stapler validate "$STAPLE_DIR/Lucas.app"
    rm -rf "$APP"
    ditto "$STAPLE_DIR/Lucas.app" "$APP"
    rm -rf "$STAPLE_DIR"
else
    echo "warning: LUCAS_NOTARY_PROFILE not set; skipping notarization" >&2
fi

mkdir -p "$UPDATES"
rm -f "$UPDATES/Lucas-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$UPDATES/Lucas-$VERSION.zip"

echo "generating appcast…"
# Sparkle rejects archives that contain the same bundle version (zip + dmg),
# so generate from a zip-only staging directory and copy the feed back.
APPCAST_DIR="$ROOT/.appcast-staging"
rm -rf "$APPCAST_DIR"
mkdir -p "$APPCAST_DIR"
cp "$UPDATES"/*.zip "$APPCAST_DIR"/ 2>/dev/null || true
cp "$UPDATES"/*.html "$APPCAST_DIR"/ 2>/dev/null || true
./tools/bin/generate_appcast \
    --ed-key-file "$KEY" \
    --download-url-prefix "$DOWNLOAD_PREFIX" \
    "$APPCAST_DIR"
cp "$APPCAST_DIR/appcast.xml" "$UPDATES/"
rm -rf "$APPCAST_DIR"

echo
echo "artifact: $UPDATES/Lucas-$VERSION.zip"
echo "appcast:  $UPDATES/appcast.xml"

echo "building dmg…"
./scripts/package-dmg.sh >/dev/null
cp "$ROOT/build/Lucas-$VERSION.dmg" "$UPDATES/"
echo "dmg:      $UPDATES/Lucas-$VERSION.dmg"

if [ -n "${LUCAS_NOTARY_PROFILE:-}" ]; then
    echo "notarizing dmg…"
    xcrun notarytool submit "$UPDATES/Lucas-$VERSION.dmg" \
        --keychain-profile "$LUCAS_NOTARY_PROFILE" \
        ${NOTARY_KEYCHAIN_ARGS[@]+"${NOTARY_KEYCHAIN_ARGS[@]}"} --wait
    xcrun stapler staple "$UPDATES/Lucas-$VERSION.dmg"
    xcrun stapler validate "$UPDATES/Lucas-$VERSION.dmg"
    # Keep build/ in sync with the stapled DMG source app already stapled above.
    cp "$UPDATES/Lucas-$VERSION.dmg" "$ROOT/build/Lucas-$VERSION.dmg"
else
    echo "warning: skipping DMG notarization (no LUCAS_NOTARY_PROFILE)" >&2
fi

if [ -n "${LUCAS_DEPLOY_TARGET:-}" ]; then
    echo "uploading to $LUCAS_DEPLOY_TARGET"
    KNOWN_HOSTS="${LUCAS_KNOWN_HOSTS:-$HOME/Library/Application Support/Lucas/known_hosts}"
    mkdir -p "$(dirname "$KNOWN_HOSTS")"
    RSYNC_SSH="ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KNOWN_HOSTS"
    if [ -n "${LUCAS_SSH_KEY:-}" ]; then
        RSYNC_SSH="$RSYNC_SSH -i $LUCAS_SSH_KEY"
    fi
    rsync -av -e "$RSYNC_SSH" "$UPDATES/" "$LUCAS_DEPLOY_TARGET/"
    echo "deployed"
else
    echo "upload manually, e.g.:"
    echo "  rsync -av \"$UPDATES/\" user@server:/var/www/updates/lucas/"
fi
