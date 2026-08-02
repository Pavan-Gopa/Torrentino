#!/usr/bin/env bash
#
# QA WP-06 — Clean / unclean shutdown flag (feature 6).
#
# Verifies via TorrentinoEngineAgentPersistenceTests:
#   * after a fully clean close the next open reports cleanShutdown == true
#     (the flag is the LAST durable write of the clean-shutdown pipeline)
#   * after a kill -9 (unclean close) the next open reports cleanShutdown ==
#     false, even though every record survives
#   * desired states (torrent state, info hash, addedAt, name) survive a
#     clean close/reopen round-trip
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running persistence clean/unclean shutdown flag tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testThreeCleanRestoreCycles \
    -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testRepeatedKillNineRestore \
    -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testDesiredStatesPersisted \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Clean/unclean shutdown flag tests FAILED"
fi
qa_ok "clean_shutdown true after clean close, false after kill -9 GREEN"

qa_pass
