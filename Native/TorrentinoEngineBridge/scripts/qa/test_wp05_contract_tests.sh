#!/usr/bin/env bash
#
# QA WP-05 — Contract tests: xcodebuild test TorrentinoIPCTests + TorrentinoAppTests.
#
# Verifies:
#   * All TorrentinoIPCTests pass (73+ tests)
#   * All TorrentinoAppTests pass
#   * All TorrentinoDomainTests pass
#   * Combined test run GREEN
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running TorrentinoIPCTests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoIPCTests \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -100

IPC_RC=${PIPESTATUS[0]}
if [[ ${IPC_RC} -ne 0 ]]; then
    qa_die "TorrentinoIPCTests FAILED"
fi
qa_ok "TorrentinoIPCTests GREEN"

qa_log "Running TorrentinoAppTests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoAppTests \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -50

APP_RC=${PIPESTATUS[0]}
if [[ ${APP_RC} -ne 0 ]]; then
    qa_die "TorrentinoAppTests FAILED"
fi
qa_ok "TorrentinoAppTests GREEN"

qa_log "Running TorrentinoDomainTests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoDomainTests \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -50

DOMAIN_RC=${PIPESTATUS[0]}
if [[ ${DOMAIN_RC} -ne 0 ]]; then
    qa_die "TorrentinoDomainTests FAILED"
fi
qa_ok "TorrentinoDomainTests GREEN"

qa_log "Running ALL test targets together..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoDomainTests \
    -only-testing:TorrentinoIPCTests \
    -only-testing:TorrentinoAppTests \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -100

ALL_RC=${PIPESTATUS[0]}
if [[ ${ALL_RC} -ne 0 ]]; then
    qa_die "Combined test run FAILED"
fi
qa_ok "Combined test run GREEN"

qa_pass