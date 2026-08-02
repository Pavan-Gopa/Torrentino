#!/usr/bin/env bash
#
# QA WP-05 — Pagination: bounded 200, cursor round-trip, hierarchical file paging.
#
# Verifies via existing unit tests:
#   * PageSize.maximum == 200
#   * PageSize.bounded clamps to 1...200
#   * PageCursor Codable round-trip
#   * FileCursor hierarchical round-trip
#   * Page<T> round-trip for all paginated types
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running TorrentinoIPCTests pagination tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testPageCursorRoundTrip \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testFileCursorHierarchyRoundTrip \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testPageRoundTrip \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testPageSizeBounded \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testPaginatedItemsRoundTrip \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Pagination tests FAILED"
fi
qa_ok "Pagination tests GREEN"

qa_pass