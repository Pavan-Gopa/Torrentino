#!/usr/bin/env bash
#
# QA WP-06 — Quarantine (feature 8).
#
# Verifies via TorrentinoEngineAgentPersistenceTests:
#   * a corrupt resume record (checksum mismatch on startup) is moved into
#     the quarantine table with its payload preserved for forensics
#   * the owning torrent is marked needs-recheck
#   * the corrupt record is never served (resumeData returns nil)
#   * every OTHER record keeps serving — the store never crashes and keeps
#     answering reads (store keeps serving, 5/5 torrents still listed)
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running quarantine tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testCorruptResumeQuarantinedAndTorrentRechecked \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Quarantine tests FAILED"
fi
qa_ok "Corrupt resume -> quarantine + needs-recheck, store keeps serving GREEN"

qa_pass
