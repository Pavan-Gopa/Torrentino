#!/usr/bin/env bash
#
# QA WP-06 — SQLite WAL mode (feature 1).
#
# Verifies via TorrentinoEngineAgentPersistenceTests:
#   * open() applies PRAGMA journal_mode=WAL (mode == "wal")
#   * synchronous=NORMAL (WAL-safe value 1)
#   * foreign_keys=ON on the store connection
#   * the WAL file exists with un-checkpointed frames after writes
#   * a clean shutdown TRUNCATE checkpoint collapses the WAL to 0 bytes
#   * reopen is idempotent (migrations never re-run)
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running persistence WAL tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testOpenCreatesSchemaWithWAL \
    -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testForensicGroupPreserved \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "SQLite WAL mode tests FAILED"
fi
qa_ok "WAL mode, checkpoint collapse, foreign_keys=ON GREEN"

qa_pass
