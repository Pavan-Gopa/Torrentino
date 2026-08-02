#!/usr/bin/env bash
#
# QA WP-06 — Failpoints (feature 12).
#
# Verifies via TorrentinoEngineAgentPersistenceTests:
#   * failpoint lifecycle: unarmed fire() is a no-op; armed fire() throws the
#     injected fault; disarm restores the no-op (all 8 FailpointIDs)
#   * Phase A — every write-path failpoint (1..6) interrupts the write AND
#     leaves clean_shutdown == false; the store keeps serving afterwards
#   * Phase B — every clean-shutdown failpoint (7..8) interrupts the pipeline
#     AND leaves clean_shutdown == false on the next boot; all records intact
#     after each interrupted phase
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running failpoint tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testFailpointLifecycle \
    -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testCleanShutdownFlagStaysFalseAtEveryInterruptedPhase \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Failpoint tests FAILED"
fi
qa_ok "All 8 failpoints leave clean_shutdown=false, records intact GREEN"

qa_pass
