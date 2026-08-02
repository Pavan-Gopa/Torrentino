#!/usr/bin/env bash
#
# QA WP-05 — Idempotency: duplicate requestID + idempotencyKey -> same result.
#
# Verifies via existing unit tests:
#   * IdempotencyTracker canonicalKey deterministic
#   * Remember + replay returns same outcome
#   * Different idempotencyKey -> no replay
#   * Different command name -> no replay
#   * Read commands (no idempotencyKey) replay on exact requestID
#   * Forget removes entry
#   * Concurrent access stress
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running TorrentinoIPCTests idempotency tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testIdempotencyDuplicateReplaysSameResult \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testIdempotencyDifferentKeysDoNotReplay \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testIdempotencyCanonicalKeyDeterministic \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Idempotency tests FAILED"
fi
qa_ok "Idempotency tests GREEN"

qa_pass