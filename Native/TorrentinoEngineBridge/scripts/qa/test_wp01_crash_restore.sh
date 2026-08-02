#!/usr/bin/env bash
#
# QA WP-01 — crash_restore scenario (feature 9).
#
# Verifies the restore-without-data-loss gate:
#   * the crash_restore scenario passes;
#   * it is a REAL kill/restore, not a no-op pass: the log must show the child
#     was SIGKILLed and that partial data was restored afterwards;
#   * the registry/session/resume artifacts survived (scenario asserts this).
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

out="$(qa_mktemp)/crash_restore.log"
qa_log "running crash_restore scenario"
set +e
bash "${RUN_TESTS_SH}" --scenario crash_restore >"${out}" 2>&1
st=$?
set -e
assert_eq "${st}" "0" "crash_restore scenario exit code"

scen_log="$(sed -n 's/.*RESULT: PASS (log: \(.*\))/\1/p' "${out}" | head -1)"
[[ -n "${scen_log}" && -f "${scen_log}" ]] || qa_die "could not locate crash_restore log"
body="$(cat "${scen_log}")"

assert_contains "${body}" "--- PASS crash_restore" "crash_restore passed"
# The scenario header names the contract being tested.
assert_contains "${body}" "restore registry + partial data" "scenario covers registry + partial data"
# Proof the scenario actually spawned and killed a child, then recovered.
assert_contains "${body}" "spawned crash child pid=" "a child process was spawned"
assert_contains "${body}" "child terminated by SIGKILL as expected" "child was SIGKILLed"
assert_match "${body}" "restored [0-9]+/[0-9]+ bytes after kill -9" "restore progress ratio present"

# Registry / session / resume / torrent survival is enforced inside the scenario
# by silent TH_REQUIRE(fs::exists(...)) checks that must all pass before the
# "--- PASS" line above is emitted; a missing artifact would FAIL the scenario.
# Here we additionally prove the restore is genuinely PARTIAL (a real mid-flight
# crash), not a trivial full-file copy: 0 < restored < total.
ratio="$(grep -oE 'restored [0-9]+/[0-9]+ bytes after kill -9' "${scen_log}" | head -1)"
restored="$(printf '%s' "${ratio}" | sed -E 's/restored ([0-9]+)\/.*/\1/')"
total="$(printf '%s' "${ratio}" | sed -E 's#restored [0-9]+/([0-9]+).*#\1#')"
assert_ge "${restored}" "1" "some partial data restored"
[[ "${restored}" -lt "${total}" ]] || qa_die "restore looks trivial (restored ${restored} >= total ${total})"
qa_ok "restore is genuinely partial (${restored} < ${total} bytes)"

qa_pass
