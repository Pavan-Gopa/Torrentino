#!/usr/bin/env bash
#
# QA WP-06 — Crash restore cycles (features 14/15/16).
#
# Verifies via TorrentinoEngineAgentPersistenceTests:
#   * 3 clean restore cycles x 30 records: all 90 records survive with their
#     resume + metainfo payloads, last shutdown flagged clean
#   * 4 repeated kill -9 cycles x 20 records: all 80 records survive,
#     no duplicates (resume_count == 80, metainfo_count == 80), flag false
#   * payload unchanged: an 8 KiB payload written 20 times and then
#     crash-restarted is returned byte-identical
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running crash restore cycle tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testThreeCleanRestoreCycles \
    -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testRepeatedKillNineRestore \
    -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testPayloadUnchangedAcrossCycles \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Crash restore cycle tests FAILED"
fi
qa_ok "90/90 clean-cycle records, 80/80 kill -9 records, 8KiB payload intact GREEN"

qa_pass
