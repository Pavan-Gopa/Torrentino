#!/usr/bin/env bash
#
# QA WP-07 — Start state + pause/resume transitions (plan WP-07 #9, #10).
#
# Verifies via TransferSmokeTests:
#   * commitAdd startPaused:true → desiredState .paused (no download)
#   * commitAdd startPaused:false → desiredState .running
#   * commitAdd startPaused:nil (default) → .running
#   * pause → .paused, resume → .running (downloading ↔ paused transitions),
#     persisted on the record
#   * the full add flow publishes a delta and survives a restart
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running start/pause/resume transition tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testCommitAddImmediateStartRuns \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testPauseResumeUpdatesRecord \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testCommitAddFlowPublishesDelta \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Start/pause/resume tests FAILED"
fi
qa_ok "Start paused/immediately + pause↔resume transitions GREEN"

qa_pass
