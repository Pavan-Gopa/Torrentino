#!/usr/bin/env bash
#
# QA WP-05 — EngineEventV1 11 events Codable round-trip (plan §7.5).
#
# Verifies via existing unit tests:
#   * All 11 events encode/decode without loss
#   * Event names (wire discriminators) are stable
#   * Event envelopes round-trip correctly
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running TorrentinoIPCTests event tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testEngineEventV1SurfaceComplete \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testEngineEventV1RoundTripAllCases \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testEventEnvelopeRoundTrip \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Event round-trip tests FAILED"
fi
qa_ok "Event round-trip tests GREEN"

qa_pass