#!/usr/bin/env bash
#
# QA WP-05 — PeerValidation: unsigned/wrong-team rejected, enforcement gate (plan §23).
#
# Verifies via existing unit tests:
#   * Frozen identity constants
#   * Team identifier frozen
#   * Enforcement gate: Debug=false, Release=true
#   * Unsigned peer rejected
#   * Wrong team rejected
#   * Invalid requirement expression rejected
#   * Nonexistent path rejected
#   * Requirement expression frozen
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running TorrentinoAppTests peer validation tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoAppTests/TorrentinoAppTests/testPeerValidationEnforcementGate \
    -only-testing:TorrentinoAppTests/TorrentinoAppTests/testPeerValidationUnsignedDummyFileRejected \
    -only-testing:TorrentinoAppTests/TorrentinoAppTests/testPeerValidationWrongTeamIdentifierRejected \
    -only-testing:TorrentinoAppTests/TorrentinoAppTests/testPeerValidationInvalidRequirementExpressionRejected \
    -only-testing:TorrentinoAppTests/TorrentinoAppTests/testPeerValidationNonexistentPathRejected \
    -only-testing:TorrentinoAppTests/TorrentinoAppTests/testPeerValidationRequirementExpressionFrozen \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Peer validation tests FAILED"
fi
qa_ok "Peer validation tests GREEN"

qa_pass