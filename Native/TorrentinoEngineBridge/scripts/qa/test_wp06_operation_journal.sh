#!/usr/bin/env bash
#
# QA WP-06 — Operation journal (feature 5).
#
# Verifies via TorrentinoEngineAgentPersistenceTests:
#   * 1100 appends are trimmed to exactly the 1000-entry cap
#   * pending entries are visible as replay candidates before shutdown
#   * a CLEAN shutdown truncates the journal to 0 entries
#   * pending entries survive an unclean close and are replayed on reopen
#     (journalReplayed >= 1, torrent marked needs-recheck)
#   * replayed entries are never replayed twice (2nd reopen: replayed == 0)
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running persistence operation journal tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testJournalCapAndCleanTruncation \
    -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testJournalReplayMarksTorrentsForRecheck \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Operation journal tests FAILED"
fi
qa_ok "Journal cap 1000, clean truncation, single replay GREEN"

qa_pass
