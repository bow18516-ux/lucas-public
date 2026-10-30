#!/bin/bash
# One-command release from your own Terminal (needs login keychain access).
#
#   cp Config/release.env.example Config/release.env
#   $EDITOR Config/release.env
#   ./scripts/publish.sh 0.5.1
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/Config/release.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "missing $ENV_FILE" >&2
    echo "  cp Config/release.env.example Config/release.env" >&2
    exit 1
fi

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: ./scripts/publish.sh <version>" >&2
    exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

echo "signing identity: ${LUCAS_SIGN_IDENTITY:-<unset>}"
echo "feed:             ${LUCAS_FEED_URL:-<unset>}"
echo "deploy:           ${LUCAS_DEPLOY_TARGET:-<unset>}"
echo

# Generate release notes from git commits unless the author wrote them.
"$ROOT/scripts/release-notes.sh" "$VERSION"

"$ROOT/scripts/release.sh" "$VERSION"

# Tag the published state so the next release notes only include new commits.
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$ROOT" tag -a "v$VERSION" -m "Lucas Agent $VERSION" 2>/dev/null || true
    echo "tagged v$VERSION"
fi
