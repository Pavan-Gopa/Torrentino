#!/usr/bin/env bash
#
# QA WP-04 — ASan/UBSan/TSan sanitizer runs: 0 reports.
#
# Wraps run_bridge_sanitizers.sh and asserts zero sanitizer reports across
# AddressSanitizer, UndefinedBehaviorSanitizer, and ThreadSanitizer. The script
# must exit 0 and the log must contain no sanitizer error indicators.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

SANITIZERS_SH="${SCRIPTS_DIR}/run_bridge_sanitizers.sh"
assert_file "${SANITIZERS_SH}" "run_bridge_sanitizers.sh present"

# --- Run all three sanitizer passes -------------------------------------------
LOG="$(qa_mktemp)/sanitizers.log"
set +e
bash "${SANITIZERS_SH}" 2>&1 | tee "${LOG}"
rc=${PIPESTATUS[0]}
set -e

[[ ${rc} -eq 0 ]] || qa_die "run_bridge_sanitizers.sh failed (rc=${rc}); see ${LOG}"

OUTPUT="$(cat "${LOG}")"

# --- Assert no sanitizer reports in the combined log --------------------------
asan_hits="$(grep -cE 'ERROR: AddressSanitizer|runtime error:|SUMMARY: UndefinedBehaviorSanitizer' "${LOG}" || true)"
tsan_hits="$(grep -cE 'WARNING: ThreadSanitizer|SUMMARY: ThreadSanitizer' "${LOG}" || true)"

assert_eq "${asan_hits}" "0" "ASan/UBSan reports = 0"
assert_eq "${tsan_hits}" "0" "TSan reports = 0"

# The script's own PASS banner
assert_contains "${OUTPUT}" "RESULT: PASS" "sanitizer suite overall PASS"

# Verify both passes actually ran (not skipped)
assert_contains "${OUTPUT}" "building bridge smoke [asan/ubsan]" "ASan/UBSan build step ran"
assert_contains "${OUTPUT}" "building bridge smoke [tsan]"       "TSan build step ran"
assert_contains "${OUTPUT}" "running bridge smoke [asan/ubsan]"  "ASan/UBSan run step ran"
assert_contains "${OUTPUT}" "running bridge smoke [tsan]"        "TSan run step ran"

qa_pass
