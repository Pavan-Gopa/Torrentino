#!/usr/bin/env bash
#
# QA WP-07 — MetainfoParser limits (plan WP-07 #2).
#
# Verifies via TransferSmokeTests:
#   * valid single-file / multi-file metainfo
#   * negative corpus (missing info, bad pieces, empty name, traversal paths)
#   * SHA-1 info hash against an independent known vector (BEP-3)
#   * file-count limit: exactly 10 000 accepted, 10 001 → .tooManyFiles
#   * tracker cap: announce-list >512 → exactly 512 deduplicated trackers
#   * piece sanity: 0 pieces / non-multiple-of-20 → .invalidPieces
#   * preflight: >10 MiB and zero total size rejected
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running metainfo parser limit tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testMetainfoSingleFileParse \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testMetainfoMultiFileParse \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testMetainfoNegativeCorpusRejects \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testMetainfoRejectsBadInfoDictionary \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testMetainfoSHA1KnownVector \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testMetainfoFileCountLimitExactBoundary \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testMetainfoTrackerLimitCappedAt512 \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testMetainfoPiecesSanityTyped \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testPreflightRejectsOversizeAndZeroTotal \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Metainfo parser tests FAILED"
fi
qa_ok "Metainfo single/multi-file + SHA-1 vector + 10k files + 512 trackers + pieces sanity GREEN"

qa_pass
