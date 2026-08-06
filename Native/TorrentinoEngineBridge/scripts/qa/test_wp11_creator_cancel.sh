#!/usr/bin/env bash
#
# QA WP-11 - Creator cancellation and atomic output transaction.
#
# Verifies:
#   * cancellation before or during hashing fails closed (operationCancelled)
#   * atomic output transaction leaves no temp or final artifacts on cancel
#   * CPUHasher reports monotonic progress and respects cancellation
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

qa_log "Running WP-11 Creator cancellation XCTests..."
xcodebuild test -project "${NATIVE_DIR}/Torrentino.xcodeproj" -scheme Torrentino \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:TorrentinoEngineAgentTests/TorrentCreatorAgentTests/testCancelBeforeHashingFailsClosed \
  -only-testing:TorrentinoEngineAgentTests/TorrentCreatorAgentTests/testWP11CPUHasherProgressETAAndCancel \
  > /dev/null

qa_ok "Creator cancellation and atomic output transaction GREEN"
qa_pass
