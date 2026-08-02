#!/usr/bin/env bash
#
# QA WP-06 — Startup reconciliation (feature 7).
#
# Verifies via TorrentinoEngineAgentPersistenceTests:
#   * an unclean boot triggers the reconciliation pass and every record
#     survives it (4 kill -9 cycles, 80/80 records, no duplicates)
#   * a record that exists ONLY in the WAL is restored by SQLite replay
#     during the reconciliation open
#   * pending journal entries are replayed (torrents marked needs-recheck)
#   * replayed entries are flagged and never re-replayed in a later session
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running startup reconciliation tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testRepeatedKillNineRestore \
    -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testRecordOnlyInWALRestoredAfterCrash \
    -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testJournalReplayMarksTorrentsForRecheck \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Startup reconciliation tests FAILED"
fi
qa_ok "Unclean boot reconciled, all records survive, replay single-shot GREEN"

qa_pass
