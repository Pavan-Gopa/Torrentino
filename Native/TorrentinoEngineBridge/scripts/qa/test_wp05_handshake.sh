#!/usr/bin/env bash
#
# QA WP-05 — Handshake: version negotiation, floor selection, mismatch (plan §7.4, §10).
#
# Verifies via existing unit tests:
#   * HelloRequest/HelloResponse Codable round-trip
#   * Negotiate same version -> negotiated
#   * Negotiate major mismatch -> mismatch
#   * Negotiate overlap -> floor (smallest overlapping)
#   * Negotiate picks most conservative (floor)
#   * Validate response mismatch -> protocolVersionMismatch fault
#   * Validate response happy path
#   * Full flow: client 1.0, server 2.0 -> mismatch fault
#   * Version parsing
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running TorrentinoIPCTests handshake tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testHelloRequestResponseRoundTrip \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testHandshakeNegotiatesSameVersion \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testHandshakeMismatchAcrossMajors \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testHandshakeNegotiatesOverlap \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testHandshakePicksMostConservativeOverlap \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testHandshakeValidateResponseMismatchFault \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testHandshakeValidateResponseHappy \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testVersionMismatchProducesFault \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testVersionParsingFromAdvertisedString \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -40

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Handshake tests FAILED"
fi
qa_ok "Handshake tests GREEN"

qa_pass