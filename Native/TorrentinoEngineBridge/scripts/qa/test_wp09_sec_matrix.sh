#!/usr/bin/env bash
#
# QA WP-09 security matrix - runtime contract tests for WP-09 security
# surfaces (ADR-014).
#
# Runs the dedicated WP-09 security XCTest cases that prove, at runtime and
# with disposable local fixtures, that:
#   - proxy password / secrets do not leak into renderable snapshots, deltas,
#     or settings/system events;
#   - a symlinked save location with a spoofed volumeIdentifier is rejected
#     (no silent acceptance of a foreign volume), and a missing volume path is
#     never auto-created.
#
# Engagement rules (ADR-014): local TestProfile/mktemp fixtures only; no
# attacks on external hosts or third parties; no product code patches.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "${ROOT_DIR}"

xcodebuild test \
  -project Native/Torrentino.xcodeproj \
  -scheme Torrentino \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testWP09SecurityNoSecretLeakageInSnapshotsAndEvents \
  -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testWP09SecuritySymlinkedSaveLocationVolumeSpoofingRejected

echo "WP-09 security matrix: PASS"
