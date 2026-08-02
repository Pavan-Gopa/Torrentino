#!/usr/bin/env bash
#
# QA WP-05 — Error contract: EngineFault structure (plan §7.6).
#
# Verifies via existing unit tests:
#   * EngineFault Codable round-trip
#   * localizationKey is string catalog key, never raw error text
#   * recoveryActions present for all faults
#   * EngineErrorCode raw values frozen
#   * FaultSeverity cases present
#   * Factory methods produce correct faults
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running TorrentinoIPCTests error contract tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testEngineFaultRoundTrip \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testEngineFaultLocalizationKeyStable \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testEngineFaultFactories \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Error contract tests FAILED"
fi
qa_ok "Error contract tests GREEN"

qa_pass