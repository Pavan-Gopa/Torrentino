#!/usr/bin/env bash
#
# QA WP-07 — PathValidator traversal corpus (plan WP-07 #7, gate:
# "untrusted source cannot create a path outside the validated torrent root").
#
# Verifies via TransferSmokeTests:
#   * negative corpus: ../, a/../../, absolute, "a//b", "a/./b", ".", "..",
#     empty, backslash escapes, reserved device names (con.txt, C:), null
#     bytes, overlong paths (300 chars, 600 components)
#   * positive controls (a.txt, spaces, unicode, .hidden) NOT rejected
#   * metainfo-level integration: traversal/absolute/null-byte paths inside a
#     .torrent are rejected during parse (before any payload write)
#   * boundaries: component 255 OK / 256 reject; total 4096 OK / 4097 reject;
#     513 components reject
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running path validator corpus tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testPathValidatorPositives \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testPathValidatorNegatives \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testMetainfoPathLengthBoundaries \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testMetainfoNegativeCorpusRejects \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Path validator tests FAILED"
fi
qa_ok "PathValidator traversal/absolute/null-byte/reserved/overlong corpus GREEN"

qa_pass
