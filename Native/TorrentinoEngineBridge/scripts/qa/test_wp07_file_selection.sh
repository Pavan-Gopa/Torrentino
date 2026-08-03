#!/usr/bin/env bash
#
# QA WP-07 — File selection round-trip (plan WP-07 #8).
#
# Verifies via TransferSmokeTests:
#   * setFileSelection with .skip/.normal priorities round-trips through
#     fetchFiles (selection reported per file)
#   * setFileSelection emits inspectionInvalidated(files) with the recordID
#   * unknown selection paths → typed .invalidPayload fault, no crash
#
# NOTE (plan-vs-product gap): FileSelectionPriority currently ships only
# {skip, normal}; the plan's "high" priority is NOT implemented in the IPC
# enum (see REPORT.md). Covered here: everything that exists.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running file selection round-trip tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testSetFileSelectionInvalidatesInspection \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testFileSelectionPrioritiesRoundTrip \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testFileSelectionRejectsUnknownPath \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "File selection tests FAILED"
fi
qa_ok "File selection priorities round-trip + inspectionInvalidated GREEN"

qa_pass
