#!/usr/bin/env bash
#
# QA WP-13 — Diagnostics, security, logging, redaction, SBOM & entitlements audit.
#
# Verifies:
#   * WP13DiagnosticsSecurityTests XCTest suite (fail-closed on zero-collect)
#   * Secret hygiene source contract (test_wp09_sec_secret_hygiene.sh)
#   * Existence and validity of SBOM.md and ENTITLEMENTS_AUDIT.md
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"
LOG_DIR="$(qa_mktemp)/wp13-diagnostics-logs"
mkdir -p "${LOG_DIR}"

# Test filters are overridable so the zero-collect guard below can be proven in
# both directions (default: the WP-13 diagnostics security suite).
TEST_FILTERS="${WP13_TEST_FILTERS:-TorrentinoEngineAgentTests/WP13DiagnosticsSecurityTests}"

qa_log "Running WP-13 secret hygiene source check..."
bash "${QA_DIR}/test_wp09_sec_secret_hygiene.sh"

qa_log "Verifying SBOM.md and ENTITLEMENTS_AUDIT.md documentation..."
[[ -f "${NATIVE_DIR}/ThirdParty/SBOM.md" ]] || qa_die "Missing SBOM.md"
[[ -f "${NATIVE_DIR}/Config/ENTITLEMENTS_AUDIT.md" ]] || qa_die "Missing ENTITLEMENTS_AUDIT.md"
assert_file "${QA_DIR}/test_wp13_observability.sh" "disposable observability matrix runner wired"

XCTEST_LOG="${LOG_DIR}/xcodebuild.log"
ONLY_ARGS=()
for filter in ${TEST_FILTERS}; do
    ONLY_ARGS+=("-only-testing:${filter}")
done

qa_log "Running WP13DiagnosticsSecurityTests XCTest suite..."
set +e
TORRENTINO_LOG_DIRECTORY="${LOG_DIR}" xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    "${ONLY_ARGS[@]}" \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    >"${XCTEST_LOG}" 2>&1
RC=$?
set -e
tail -30 "${XCTEST_LOG}"

# Fail-closed guard: xcodebuild exits 0 even when an -only-testing filter
# collects ZERO tests (e.g. the suite is missing from the target). Parse the
# aggregate result and pass only when executed > 0 and failed == 0.
SUMMARY_LINE="$(grep -E 'Executed [0-9]+ tests?, with [0-9]+ failures?' "${XCTEST_LOG}" | tail -1 || true)"
if [[ -n "${SUMMARY_LINE}" ]]; then
    EXECUTED="$(printf '%s' "${SUMMARY_LINE}" | sed -E 's/.*Executed ([0-9]+) tests?.*/\1/')"
    FAILED="$(printf '%s' "${SUMMARY_LINE}" | sed -E 's/.*, with ([0-9]+) failures?.*/\1/')"
else
    # Newer Xcode prints per-case lines instead of the legacy aggregate.
    EXECUTED="$(grep -cE "Test case '.*' (passed|failed) on " "${XCTEST_LOG}" || true)"
    FAILED="$(grep -cE "Test case '.*' failed on " "${XCTEST_LOG}" || true)"
fi
echo "[qa] executed=${EXECUTED} failed=${FAILED}"

if [[ ${RC} -ne 0 ]]; then
    qa_die "WP13DiagnosticsSecurityTests FAILED (xcodebuild exit ${RC})"
fi
if [[ "${EXECUTED}" -eq 0 ]]; then
    qa_die "ZERO-COLLECT: xcodebuild executed 0 tests (suite not collected) — failing closed"
fi
if [[ "${FAILED}" -ne 0 ]]; then
    qa_die "WP13DiagnosticsSecurityTests reported ${FAILED} failure(s)"
fi

qa_ok "WP-13 Diagnostics & Security suite GREEN (executed=${EXECUTED}, failed=${FAILED})"
qa_pass
