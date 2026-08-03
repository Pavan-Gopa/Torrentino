#!/usr/bin/env bash
#
# QA WP-07 — 100-row fixture + concurrency stress (plan WP-07 #12, #16;
# gate: "row identity, focus, scroll positions preserved under 100 rows").
#
# Verifies via TransferSmokeTests:
#   * 100 seeded records restore → snapshot renders exactly 100 rows with
#     per-row identity (recordID), metainfo-derived sizes, totals
#   * 100 interleaved commands (add/pause/resume/fetch/status) on the SAME
#     coordinator all resolve successfully (no deadlock, no dropped replies)
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running 100-row fixture + concurrency stress tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testHundredRowFixtureRestoresAndRenders \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testConcurrentMixedCommandsAllResolve \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "100-row fixture tests FAILED"
fi
qa_ok "100-row restore/render + concurrent mixed-command stress GREEN"

qa_pass
