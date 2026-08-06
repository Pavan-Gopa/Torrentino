#!/usr/bin/env bash
#
# QA WP-11 - Creator asserted CreateOptions contract (ADR-016).
#
# Verifies:
#   * CommitCreateRequest requires complete asserted CreateOptions
#   * unasserted commitCreate fails closed before scan/hash/write
#   * option mismatch fails closed (creatorAssertionMismatch)
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

qa_log "Running WP-11 Creator asserted options XCTest..."
xcodebuild test -project "${NATIVE_DIR}/Torrentino.xcodeproj" -scheme Torrentino \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:TorrentinoEngineAgentTests/TorrentCreatorAgentTests/testWP11CreatorAssertedOptionsFailClosed \
  > /dev/null

qa_ok "Creator asserted options contract GREEN"
qa_pass
