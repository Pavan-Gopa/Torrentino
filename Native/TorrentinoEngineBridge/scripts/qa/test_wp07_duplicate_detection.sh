#!/usr/bin/env bash
#
# QA WP-07 — Duplicate detection + idempotent replay (plan WP-07 #5).
#
# Verifies via TransferSmokeTests:
#   * the same .torrent file added twice → the SAME recordID
#   * the same magnet hash (different dn/tr) → the SAME recordID
#   * a different content hash → a DIFFERENT recordID
#   * replaying the same commitAdd idempotency key → the SAME record
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running duplicate detection tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testDuplicateAddReturnsExistingRecord \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testDuplicateMagnetSameHashReturnsExistingRecord \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testCommitAddIdempotentReplay \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Duplicate detection tests FAILED"
fi
qa_ok "Same content → same record; idempotent replay GREEN"

qa_pass
