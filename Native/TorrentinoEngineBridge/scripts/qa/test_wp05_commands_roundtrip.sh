#!/usr/bin/env bash
#
# QA WP-05 — EngineCommandV1 32 commands Codable round-trip (plan §7.4).
#
# Verifies via existing unit tests:
#   * All 32 commands encode/decode without loss
#   * Every payload carries requestID
#   * Mutating commands carry idempotencyKey
#   * Command names (wire discriminators) are stable
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running TorrentinoIPCTests command tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testEngineCommandV1SurfaceComplete \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testEngineCommandV1RoundTripAllCases \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testEngineCommandUnknownDecodeFails \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testEngineCommandV1MutatingCommandsCarryIdempotencyKey \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testEngineCommandV1EveryPayloadHasRequestID \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testCommandEnvelopeRoundTrip \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Command round-trip tests FAILED"
fi
qa_ok "Command round-trip tests GREEN"

qa_pass