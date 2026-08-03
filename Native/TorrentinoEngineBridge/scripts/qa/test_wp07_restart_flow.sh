#!/usr/bin/env bash
#
# QA WP-07 — Restart preserves flow (plan WP-07 #14; gate: "restart сохраняет
# flow").
#
# Verifies via TransferSmokeTests (in-process restart = fresh coordinator over
# the same TestProfile store):
#   * add → "kill" (drop the coordinator) → restoreFromPersistence → the
#     record is present with the same displayName and desiredState
#   * a 100-record store restores to a snapshot of exactly 100 rows with
#     metainfo-derived sizes and aggregate totals
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running restart-preserves-flow tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testCommitAddFlowPublishesDelta \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testHundredRowFixtureRestoresAndRenders \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Restart flow tests FAILED"
fi
qa_ok "Add → restart → restoreFromPersistence → record present GREEN"

qa_pass
