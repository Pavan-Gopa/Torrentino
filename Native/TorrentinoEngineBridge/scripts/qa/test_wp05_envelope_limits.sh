#!/usr/bin/env bash
#
# QA WP-05 — IPCEnvelope limits: 4MB max, garbage reject, unknown kind fail.
#
# Verifies via existing unit tests:
#   * IPCPayloadLimit.maxBytes == 4 MiB
#   * Payloads <= 4MB validate, > 4MB rejected
#   * Garbage JSON fails to decode
#   * Unknown envelope kind fails to decode
#   * Truncated JSON fails to decode
#   * Tampered payload fails to decode
#   * Version mismatch fault
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running TorrentinoIPCTests envelope limit tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testEnvelopeOversizedPayloadRejected \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testEnvelopeUnknownKindDecodeFails \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testEnvelopeGarbageJSONDecodeFails \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testEnvelopeFuzzTruncatedJSON \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testEnvelopeTamperedPayloadDecodeFails \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testEnvelopeRequestIDMismatch \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testVersionBackwardCompatLogicViaEnvelope \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testVersionMismatchProducesFault \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -40

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Envelope limit tests FAILED"
fi
qa_ok "Envelope limit tests GREEN"

qa_pass