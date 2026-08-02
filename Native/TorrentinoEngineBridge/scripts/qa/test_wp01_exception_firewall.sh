#!/usr/bin/env bash
#
# QA WP-01 — C-ABI exception firewall (feature 8).
#
# Verifies:
#   * the exception_containment scenario passes (garbage bdecode, empty magnet,
#     throw 42 — all contained);
#   * the firewall is actually wired in source: std::set_terminate in
#     harness_api.cpp and run_guarded in support.cpp;
#   * misuse (unknown scenario, missing arg, unknown flag) returns the
#     usage_error exit code (6) instead of crashing, and never reaches
#     std::terminate — i.e. errors stay inside the harness.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"
source "${LOCK_FILE}"
BIN="${BRIDGE_DIR}/.build/harness-${LT_DEFAULT_VERSION}-release/torrentino-harness"
[[ -x "${BIN}" ]] || qa_die "harness binary missing: ${BIN}"
USAGE_ERROR=6

# --- dynamic: the containment scenario -------------------------------------
out="$(qa_mktemp)/exception.log"
set +e
bash "${RUN_TESTS_SH}" --scenario exception_containment >"${out}" 2>&1
st=$?
set -e
assert_eq "${st}" "0" "exception_containment scenario exit code"
scen_log="$(sed -n 's/.*RESULT: PASS (log: \(.*\))/\1/p' "${out}" | head -1)"
[[ -n "${scen_log}" && -f "${scen_log}" ]] || qa_die "could not locate exception_containment log"
body="$(cat "${scen_log}")"
assert_contains "${body}" "--- PASS exception_containment" "exception_containment passed"
assert_contains "${body}" "all injected failures were contained inside the harness" "containment proof line"

# --- static: the firewall is wired in --------------------------------------
assert_contains "$(cat "${BRIDGE_DIR}/harness/src/harness_api.cpp")" "std::set_terminate" "set_terminate installed"
assert_contains "$(cat "${BRIDGE_DIR}/harness/src/harness_api.cpp")" "catch (...)" "catch-all at the C boundary"
assert_contains "$(cat "${BRIDGE_DIR}/harness/src/support.cpp")" "run_guarded" "run_guarded present in support.cpp"

# --- dynamic: misuse is contained, never a terminate -----------------------
check_contained() { # <message> <arg...>
	local msg="$1"; shift
	local o s
	set +e
	o="$("${BIN}" "$@" 2>&1)"
	s=$?
	set -e
	assert_eq "${s}" "${USAGE_ERROR}" "${msg}: exit code is usage_error"
	assert_not_contains "${o}" "std::terminate reached" "${msg}: no terminate reached"
	assert_not_contains "${o}" "libc++abi" "${msg}: no uncaught-exception abort"
}
check_contained "unknown scenario" run no_such_scenario
check_contained "missing run argument" run
check_contained "unknown option" --bogus-flag

qa_pass
