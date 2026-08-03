#!/usr/bin/env bash
#
# QA WP-07 — BencodeParser boundedness (plan WP-07 #1).
#
# Verifies via TransferSmokeTests:
#   * valid dict/list/int/string parse
#   * negative corpus (truncated, unterminated, leading-zero, negative
#     length, non-digit, trailing garbage, nested too deep) rejects
#   * depth boundary: 64 nested OK, 66 → .depthExceeded
#   * size bound: >16 MiB rejects BEFORE tokenizing
#   * strict integer grammar: leading zero, -0, empty, non-digit, overflow
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running bencode parser boundedness tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testBencodePositiveInputsParse \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testBencodeNegativeCorpusRejects \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testBencodeDepthBoundary \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testBencodeInputSizeBound \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testBencodeStrictIntegerFormsTyped \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Bencode parser tests FAILED"
fi
qa_ok "Bencode happy + negative corpus + depth/size/lenient-integer bounds GREEN"

qa_pass
