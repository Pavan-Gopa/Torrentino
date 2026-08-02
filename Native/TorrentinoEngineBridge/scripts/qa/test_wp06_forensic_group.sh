#!/usr/bin/env bash
#
# QA WP-06 — Forensic group (feature 11).
#
# Verifies via TorrentinoEngineAgentPersistenceTests:
#   * after an unclean close the trio is intact: main exists, WAL exists with
#     un-checkpointed frames (WAL size > 0) — nothing is deleted or truncated
#   * a clean shutdown collapses the trio: WAL is TRUNCATE-checkpointed to
#     zero bytes and only the main file remains authoritative
#   * on rebuild the corrupt group (main + WAL + SHM) is moved aside TOGETHER
#     into a single corrupt-* directory, and the preserved main file is
#     readable from it (salvage source)
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running forensic group tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testForensicGroupPreserved \
    -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testCorruptDatabaseControlledRecovery \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Forensic group tests FAILED"
fi
qa_ok "Main+WAL+SHM trio preserved, moved together on rebuild GREEN"

qa_pass
