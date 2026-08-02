#!/usr/bin/env bash
#
# QA WP-01 — harness scenario suite, default libtorrent (feature 3).
#
# Verifies:
#   * run_tests.sh (default = versions.lock LT_DEFAULT_VERSION / release) exits 0;
#   * all 11 scenarios PASS and none FAIL;
#   * the suite summary is "11 passed, 0 failed";
#   * each named scenario appears as "--- PASS <name>".
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

SCENARIOS="session_lifecycle torrent_creation add_torrent_file info_hash_recognition \
pause_resume resume_data session_state exception_containment magnet_metadata \
data_transfer crash_restore"

out="$(qa_mktemp)/run_tests.log"
qa_log "running full scenario suite (default libtorrent)"
set +e
bash "${RUN_TESTS_SH}" >"${out}" 2>&1
status=$?
set -e
assert_eq "${status}" "0" "run_tests.sh exit code"
assert_contains "$(cat "${out}")" "RESULT: PASS" "suite result banner"

# Locate the scenarios.log the runner wrote (path is in the RESULT banner).
scen_log="$(sed -n 's/.*RESULT: PASS (log: \(.*\))/\1/p' "${out}" | head -1)"
[[ -n "${scen_log}" && -f "${scen_log}" ]] || qa_die "could not locate scenarios.log from runner output"
qa_log "scenarios log: ${scen_log}"
body="$(cat "${scen_log}")"

pass_count="$(grep -c -- '--- PASS' "${scen_log}" || true)"
fail_count="$(grep -c -- '--- FAIL' "${scen_log}" || true)"
assert_eq "${pass_count}" "11" "number of PASS scenarios"
assert_eq "${fail_count}" "0" "number of FAIL scenarios"
assert_contains "${body}" "11 passed, 0 failed" "suite summary line"

for s in ${SCENARIOS}; do
	assert_contains "${body}" "--- PASS ${s}" "scenario ${s} passed"
done

qa_pass
