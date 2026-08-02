#!/usr/bin/env bash
#
# QA WP-06 — Advisory lock, single writer (feature 13).
#
# Verifies via TorrentinoEngineAgentPersistenceTests:
#   * flock(LOCK_EX | LOCK_NB) on the data directory lock file: the first
#     writer acquires the lock
#   * a SECOND acquire on the same directory is rejected with
#     AdvisoryLockError.alreadyLocked — no blocking, no WAL corruption risk
#   * after release() the lock is acquirable again (release is idempotent)
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running advisory lock tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testAdvisoryLockSingleWriter \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Advisory lock tests FAILED"
fi
qa_ok "Second writer rejected with alreadyLocked, reacquire works GREEN"

qa_pass
