#!/usr/bin/env bash
# Build, unit tests, then the local daemon smoke test.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
swift test
bash scripts/smoke_test.sh
