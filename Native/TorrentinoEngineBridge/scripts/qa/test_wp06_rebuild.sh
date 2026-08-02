#!/usr/bin/env bash
#
# QA WP-06 — Controlled recovery / rebuild (feature 9).
#
# Verifies via TorrentinoEngineAgentPersistenceTests:
#   * a garbage main database (bit-rot / torn file) does NOT crash open():
#     the store reports rebuilt == true and degraded == true
#   * the forensic trio is moved aside into a corrupt-* directory BEFORE the
#     rebuild (evidence preserved, salvageable rows read from it)
#   * the rebuilt store is fully usable: new torrents, resume writes and
#     reads all work in degraded mode
#   * the rebuilt database starts with clean_shutdown == false
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running controlled recovery / rebuild tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testCorruptDatabaseControlledRecovery \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Controlled recovery tests FAILED"
fi
qa_ok "Garbage DB -> rebuilt + degraded, store usable, trio preserved GREEN"

qa_pass
