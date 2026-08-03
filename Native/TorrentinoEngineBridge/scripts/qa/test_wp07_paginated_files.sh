#!/usr/bin/env bash
#
# QA WP-07 — Paginated files drill-down (plan WP-07 #11).
#
# Verifies via TransferSmokeTests:
#   * multi-file torrent: root page shows the shared directory first
#   * FileCursor drill-down root → root/sub → root/sub/deep
#   * opaque PageCursor round-trip: page of 2 then page of 1, last page
#     carries nil nextCursor
#   * directory entries aggregate children (no partial dir rows)
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running paginated files drill-down tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testFilesPageWithDirectoryDrillDown \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testSetFileSelectionInvalidatesInspection \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Paginated files tests FAILED"
fi
qa_ok "Paginated files root-first drill-down + cursor round-trip GREEN"

qa_pass
