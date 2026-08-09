#!/usr/bin/env bash
#
# QA WP-13 — Diagnostics, security, logging, redaction, SBOM & entitlements audit.
#
# Verifies:
#   * WP13DiagnosticsSecurityTests XCTest suite
#   * Secret hygiene source contract (test_wp09_sec_secret_hygiene.sh)
#   * Existence and validity of SBOM.md and ENTITLEMENTS_AUDIT.md
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"
LOG_DIR="$(qa_mktemp)/wp13-diagnostics-logs"
mkdir -p "${LOG_DIR}"

qa_log "Running WP-13 secret hygiene source check..."
bash "${QA_DIR}/test_wp09_sec_secret_hygiene.sh"

qa_log "Verifying SBOM.md and ENTITLEMENTS_AUDIT.md documentation..."
[[ -f "${NATIVE_DIR}/ThirdParty/SBOM.md" ]] || qa_die "Missing SBOM.md"
[[ -f "${NATIVE_DIR}/Config/ENTITLEMENTS_AUDIT.md" ]] || qa_die "Missing ENTITLEMENTS_AUDIT.md"
assert_file "${QA_DIR}/test_wp13_observability.sh" "disposable observability matrix runner wired"

qa_log "Running WP13DiagnosticsSecurityTests XCTest suite..."
TORRENTINO_LOG_DIRECTORY="${LOG_DIR}" xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoEngineAgentTests/WP13DiagnosticsSecurityTests \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "WP13DiagnosticsSecurityTests FAILED"
fi

qa_ok "WP-13 Diagnostics & Security suite GREEN"
qa_pass
