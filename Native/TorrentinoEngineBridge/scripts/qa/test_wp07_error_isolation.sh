#!/usr/bin/env bash
#
# QA WP-07 — Error isolation (plan WP-07 #13; gate: "one torrent error does
# not block the others").
#
# Verifies via TransferSmokeTests:
#   * engine add failure for one magnet degrades ONLY that record
#     (.recoverableError(.engineBusy)); siblings stay healthy
#   * pause/resume on healthy records keep working while one record is
#     degraded (no blocking)
#   * when the engine recovers, the next pump re-adds the isolated record
#     and heals it (.healthy)
#   * a per-record engine error status degrades only that record and healthy
#     records keep live rates
#   * commitAdd without a prior inspect → typed .operationNotFound fault
#     (no crash, store keeps serving)
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running error isolation tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testEngineAddFailureIsolatesRecord \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testEngineStatusErrorDegradesOnlyThatRecord \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testCommitAddWithoutInspectFails \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Error isolation tests FAILED"
fi
qa_ok "Per-record engine fault isolation (others continue) GREEN"

qa_pass
