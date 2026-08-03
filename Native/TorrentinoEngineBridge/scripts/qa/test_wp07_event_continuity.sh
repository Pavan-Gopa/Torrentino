#!/usr/bin/env bash
#
# QA WP-07 — Event-driven deltas (plan WP-07 #15; gate: "UI не polling full
# list").
#
# Verifies via TransferSmokeTests:
#   * commitAdd publishes a .torrentDelta with the added record (no polling)
#   * two rapid adds coalesce into ONE batch with CONTIGUOUS revisions
#     (delta continuity — the UI never sees a gap)
#   * .snapshotRequired is URGENT: bypasses a 5 s coalescing window
#   * a burst of publishes coalesces into a single delivery
#   * setFileSelection publishes .inspectionInvalidated(files)
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running event continuity tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testCommitAddFlowPublishesDelta \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testDeltaContinuityTwoAddsSingleBatch \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testSnapshotRequiredFlushesImmediately \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testEventBusCoalescesBurstIntoOneDelivery \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testSetFileSelectionInvalidatesInspection \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Event continuity tests FAILED"
fi
qa_ok "Delta continuity + urgent snapshotRequired + coalescing GREEN"

qa_pass
