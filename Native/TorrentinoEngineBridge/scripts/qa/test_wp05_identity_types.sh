#!/usr/bin/env bash
#
# QA WP-05 — Identity model (plan §7.1).
#
# Verifies via existing unit tests:
#   * TorrentRecordID Codable round-trip, Hashable, Sendable
#   * ContentIdentity Codable round-trip, isKnown, hybrid v1+v2
#   * AddOperationID, RequestID, IdempotencyKey round-trip
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running TorrentinoIPCTests identity model tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testTorrentRecordIDRoundTripAndDescription \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testContentIdentityRoundTripHybrid \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testContentIdentityUnknownBothNil \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testAddOperationIDAndRequestIDRoundTrip \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testIdempotencyKeyRoundTrip \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Identity model tests FAILED"
fi
qa_ok "Identity model tests GREEN"

qa_pass