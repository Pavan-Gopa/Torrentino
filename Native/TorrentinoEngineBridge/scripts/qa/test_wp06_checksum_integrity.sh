#!/usr/bin/env bash
#
# QA WP-06 — SHA-256 checksum integrity (feature 4).
#
# Verifies via TorrentinoEngineAgentPersistenceTests:
#   * a payload whose stored checksum does not match its SHA-256 is DETECTED
#     (report.checksumFailures >= 1)
#   * the corrupt record is quarantined, never served, never crashes the store
#   * other records remain fully readable (checksum-verified on every read)
#   * a legitimate 8 KiB payload survives 20 writes + a crash restart and is
#     returned byte-identical (checksum matches on every read path)
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running persistence checksum integrity tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testCorruptResumeQuarantinedAndTorrentRechecked \
    -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testPayloadUnchangedAcrossCycles \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Checksum integrity tests FAILED"
fi
qa_ok "Checksum mismatch detected, byte-identical payload GREEN"

qa_pass
