#!/usr/bin/env bash
#
# QA WP-10 — durable storage move + crash recovery (XCTest gates).
#
# Verifies via WPSafeFileOperationsTests:
#   * moveStorage updates the record's save location durably, drops the journal
#     row on success, issues the engine move, and force-rechecks the payload
#   * an engine move failure leaves a 'prepared'/'failed' journal row and keeps
#     the origin save location
#   * crash recovery (restoreFromPersistence) is evidence-based:
#       - engine_moved + destination exists  -> resume (record moved, row gone)
#       - prepared + origin intact           -> rollback no-op (row gone)
#       - engine_moved + destination missing -> guided (row KEPT, no silent
#         auto-resume, record never rewritten)
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running WP-10 storage move + recovery gates..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10MoveStorageUpdatesSaveLocationDurablyAndRechecks \
    -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10MoveStorageEngineFailureLeavesJournalForRecovery \
    -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10MoveRecoveryResumesInterruptedMove \
    -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10MoveRecoveryRollsBackNeverStartedMove \
    -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10MoveRecoveryGuidedKeepsJournalWhenEvidenceAmbiguous \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "WP-10 storage move + recovery gates FAILED"
fi
qa_ok "move journal + save-location persistence + recheck + resume/rollback/guided recovery GREEN"

qa_pass
