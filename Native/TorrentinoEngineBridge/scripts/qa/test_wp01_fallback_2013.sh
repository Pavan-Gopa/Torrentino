#!/usr/bin/env bash
#
# QA WP-01 — fallback libtorrent 2.0.13 (feature 4).
#
# Verifies:
#   * run_tests.sh --lt-version 2.0.13 exits 0 with all 11 scenarios PASS;
#   * the 2.0.13 harness binary genuinely links libtorrent 2.0.13 (not 2.1.0).
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"
source "${LOCK_FILE}"

FALLBACK="2.0.13"
case " ${LT_SUPPORTED_VERSIONS} " in
	*" ${FALLBACK} "*) qa_ok "${FALLBACK} is a pinned fallback" ;;
	*) qa_die "${FALLBACK} not pinned in versions.lock" ;;
esac

BIN="${BRIDGE_DIR}/.build/harness-${FALLBACK}-release/torrentino-harness"
[[ -x "${BIN}" ]] || bash "${SCRIPTS_DIR}/build_harness.sh" --flavor release --lt-version "${FALLBACK}" >/dev/null

# The binary must actually report the fallback engine version.
ver_out="$("${BIN}" version 2>&1)"
assert_contains "${ver_out}" "libtorrent 2.0.13" "harness reports libtorrent 2.0.13"

out="$(qa_mktemp)/fallback.log"
qa_log "running scenario suite on libtorrent ${FALLBACK}"
set +e
bash "${RUN_TESTS_SH}" --lt-version "${FALLBACK}" >"${out}" 2>&1
status=$?
set -e
assert_eq "${status}" "0" "run_tests.sh --lt-version ${FALLBACK} exit code"
assert_contains "$(cat "${out}")" "RESULT: PASS" "fallback suite result banner"

scen_log="$(sed -n 's/.*RESULT: PASS (log: \(.*\))/\1/p' "${out}" | head -1)"
[[ -n "${scen_log}" && -f "${scen_log}" ]] || qa_die "could not locate fallback scenarios.log"
body="$(cat "${scen_log}")"
assert_eq "$(grep -c -- '--- PASS' "${scen_log}" || true)" "11" "fallback PASS count"
assert_eq "$(grep -c -- '--- FAIL' "${scen_log}" || true)" "0" "fallback FAIL count"
assert_contains "${body}" "11 passed, 0 failed" "fallback suite summary"

qa_pass
