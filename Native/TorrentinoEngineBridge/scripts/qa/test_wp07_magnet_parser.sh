#!/usr/bin/env bash
#
# QA WP-07 — MagnetParser (plan WP-07 #3).
#
# Verifies via TransferSmokeTests:
#   * valid v1 40-hex magnet parses to a 20-byte info hash
#   * valid 32-char base32 magnet decodes to the SAME bytes as the hex form
#   * short hash (39 hex) → .invalidHash
#   * v2-only (urn:btmh) → .missingHash; hybrid btih+btmh → btih identity
#   * tracker dedupe (same tr twice collapses) + scheme whitelist (ftp reject)
#   * length boundary: exactly 8 KiB accepted, 8 KiB+1 → .tooLong
#   * negative corpus + oversize URI
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running magnet parser tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testMagnetParseValid \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testMagnetBase32HashDecodesToKnownBytes \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testMagnetRejectsMissingHash \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testMagnetRejectsShortHashTyped \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testMagnetBTMHOnlyRejectedHybridUsesBTIH \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testMagnetTrackerDedupeAndSchemeWhitelist \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testMagnetLengthBoundaryExact \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testMagnetRejectsOversizeURI \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testMagnetNegativeCorpusRejects \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Magnet parser tests FAILED"
fi
qa_ok "Magnet v1/base32/btmh handling + hash bounds + tracker dedupe + 8 KiB limit GREEN"

qa_pass
