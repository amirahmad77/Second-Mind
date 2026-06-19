#!/usr/bin/env bash
# Local CI: build + run the unit tests on the iOS Simulator (no signing needed).
# Run from anywhere: ./scripts/ci.sh   (or wire into a pre-push git hook).
# Mirrors .github/workflows/ci.yml so you can verify before pushing — useful
# because the iOS 26.4 SDK isn't on GitHub-hosted runners (self-hosted only).
set -euo pipefail

cd "$(dirname "$0")/.."   # → the project dir ("NOUS 0")

DEST=${NOUS_TEST_DEST:-'platform=iOS Simulator,name=iPhone 17 Pro'}

echo "▶ Building + testing NOUS 0 on: $DEST"
xcodebuild test \
  -scheme "NOUS 0" \
  -project "NOUS 0.xcodeproj" \
  -destination "$DEST" \
  -derivedDataPath build/dd \
  CODE_SIGNING_ALLOWED=NO \
  | grep -aE "Test Suite|Executed|passed after|failed after|recorded an issue|error:|TEST (SUCCEEDED|FAILED)" \
  || { echo "✘ tests failed"; exit 1; }
echo "✔ done"
