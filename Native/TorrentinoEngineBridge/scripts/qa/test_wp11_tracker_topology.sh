#!/usr/bin/env bash
#
# QA WP-11 - Structured tracker topology contract (ADR-017).
#
# Verifies:
#   * ordered [[String]] tiers are authoritative across boundaries
#   * repeated URLs on different tiers are preserved without deduplication
#   * structured edit replaces trackerTiers; scalar delta fields are rejected
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

qa_log "Running WP-11 tracker topology XCTests..."
xcodebuild test -project "${NATIVE_DIR}/Torrentino.xcodeproj" -scheme Torrentino \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:TorrentinoEngineAgentTests/TorrentCreatorAgentTests/testWP11TrackerTopologyVectorPreservesTiersAndRepeatedURLs \
  -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testEditTrackers \
  > /dev/null

qa_ok "Structured tracker topology vector & edit GREEN"
qa_pass
