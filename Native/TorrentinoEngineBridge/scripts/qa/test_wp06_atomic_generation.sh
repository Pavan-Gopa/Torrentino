#!/usr/bin/env bash
#
# QA WP-06 — Atomic generations (feature 3).
#
# Verifies via TorrentinoEngineAgentPersistenceTests:
#   * generations are strictly monotonic (g2 > g1) within a session
#   * the read path returns the LATEST generation with its exact payload
#   * superseded generations are deleted (row count stays == torrent count)
#   * the generation clock is never reused after a crash-restart (g3 > g2
#     across an unclean close/reopen)
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running persistence atomic generation tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testNoDuplicateOrLostRecordsWithGenerations \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Atomic generation tests FAILED"
fi
qa_ok "Generations monotonic, superseded deleted, byte-identical payload GREEN"

qa_pass
