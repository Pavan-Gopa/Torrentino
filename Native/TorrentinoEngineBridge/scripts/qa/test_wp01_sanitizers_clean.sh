#!/usr/bin/env bash
#
# QA WP-01 — ASan + UBSan suite (feature 5).
#
# Verifies:
#   * run_sanitizers.sh exits 0;
#   * it reports "sanitizer reports: 0" and "RESULT: PASS — ASan/UBSan clean";
#   * the underlying log contains no AddressSanitizer/UBSanitizer diagnostics.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

out="$(qa_mktemp)/sanitizers.log"
qa_log "running ASan/UBSan scenario suite"
set +e
bash "${RUN_SANITIZERS_SH}" >"${out}" 2>&1
status=$?
set -e
assert_eq "${status}" "0" "run_sanitizers.sh exit code"

text="$(cat "${out}")"
assert_contains "${text}" "sanitizer reports: 0" "zero sanitizer reports"
assert_contains "${text}" "RESULT: PASS — ASan/UBSan clean" "sanitizer result banner"
assert_not_contains "${text}" "ERROR: AddressSanitizer" "no ASan errors in runner output"
assert_not_contains "${text}" "runtime error:" "no UBSan runtime errors in runner output"

# Double-check the detailed scenario log the runner tee'd.
det_log="$(sed -n 's/.*ASan\/UBSan clean (\(.*\))/\1/p' "${out}" | head -1)"
if [[ -n "${det_log}" && -f "${det_log}" ]]; then
	det="$(cat "${det_log}")"
	assert_not_contains "${det}" "ERROR: AddressSanitizer" "no ASan errors in detailed log"
	assert_not_contains "${det}" "SUMMARY: UndefinedBehaviorSanitizer" "no UBSan summary in detailed log"
	assert_eq "$(grep -c -- '--- FAIL' "${det_log}" || true)" "0" "no scenario failures under sanitizers"
fi

qa_pass
