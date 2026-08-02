#!/usr/bin/env bash
#
# QA WP-06 — WAL-only record recovery (feature 10).
#
# Verifies via TorrentinoEngineAgentPersistenceTests:
#   * an unclean close leaves the WAL on disk with un-checkpointed frames
#     (walExists true, WAL size > 0)
#   * a COPY of the main database has no schema/tables at all — proving the
#     record exists ONLY in WAL frames
#   * after reopen, SQLite replays the WAL and the record is restored with
#     its exact bytes (no data loss for a record that never hit main)
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running WAL-only recovery tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testRecordOnlyInWALRestoredAfterCrash \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "WAL-only recovery tests FAILED"
fi
qa_ok "WAL-only record restored after crash (bytes exact) GREEN"

qa_pass
