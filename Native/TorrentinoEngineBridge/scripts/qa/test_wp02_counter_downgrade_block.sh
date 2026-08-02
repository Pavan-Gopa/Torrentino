#!/usr/bin/env bash
#
# QA WP-02 — counter format downgrade block (feature 3c).
#
# Verifies:
#   * a v1 agent binary refuses a v2 (TTC2) counter.dat;
#   * exit code 78 (EX_CONFIG / downgradeBlocked);
#   * "Downgrade blocked" fatal message on stderr;
#   * no listener started (no residual process).
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"
source "${QA_DIR}/qa_wp02_common.sh"

wp02_require_app
wp02_trap_cleanup
wp02_reset

V1_DD="${TMPDIR:-/tmp}/torrentino-qa-wp02-v1-$$"
mkdir -p "${V1_DD}"
# Ensure DerivedData path is cleaned on EXIT (in addition to wp02 + qa cleanup).
trap 'rc=$?; wp02_cleanup; rm -rf "'"${V1_DD}"'"; qa_cleanup; exit $rc' EXIT

qa_log "building v1 agent (COUNTER_FORMAT_V1) into ${V1_DD}"
build_log="$(qa_mktemp)/v1-build.log"
set +e
xcodebuild -project "${WP02_PROJECT}" -scheme TorrentinoEngineAgent \
	-configuration Debug -derivedDataPath "${V1_DD}" \
	SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG COUNTER_FORMAT_V1' \
	build >"${build_log}" 2>&1
build_rc=$?
set -e
[[ ${build_rc} -eq 0 ]] || { tail -40 "${build_log}" >&2; qa_die "v1 agent build failed"; }
V1_BIN="${V1_DD}/Build/Products/Debug/TorrentinoEngineAgent"
assert_file "${V1_BIN}" "v1 agent binary present"
[[ -x "${V1_BIN}" ]] || qa_die "v1 agent not executable"

# Seed a v2 store via the current (v2) SMAppService agent.
wp02_register_and_wait || qa_die "register failed"
wp02_cli increment; assert_contains "${WP02_CLI_OUT}" "counter=1" "seed v2 counter"
wp02_cli health; assert_contains "${WP02_CLI_OUT}" "format=v2" "seed format v2"
wp02_cli shutdown
wp02_wait_for 10 wp02_agent_gone || true
wp02_cli unregister
launchctl bootout "${WP02_DOMAIN}/${WP02_LABEL}" >/dev/null 2>&1 || true
sleep 0.5

assert_file "${WP02_COUNTER}" "v2 counter.dat present"
assert_eq "$(wp02_counter_magic)" "TTC2" "magic is TTC2 before downgrade probe"

# --- happy path of the *block*: v1 refuses v2 ------------------------------
log="$(qa_mktemp)/downgrade.log"
set +e
"${V1_BIN}" >"${log}" 2>&1
dg_rc=$?
set -e
qa_log "v1 on v2 data rc=${dg_rc}"
cat "${log}" | while IFS= read -r line; do qa_log "  | ${line}"; done || true

assert_eq "${dg_rc}" "78" "downgrade blocked → exit 78"
body="$(cat "${log}")"
assert_contains "${body}" "Downgrade blocked" "fatal Downgrade blocked message"
wp02_agent_running && qa_die "agent process alive after downgrade block" || qa_ok "no listener after downgrade"

# --- edge: v2 file still intact (not rewritten by v1) ----------------------
assert_eq "$(wp02_counter_magic)" "TTC2" "v2 magic preserved after rejected open"

# --- edge: v2 agent still loads the same file fine --------------------------
wp02_resolve_standalone_agent || qa_die "standalone v2 agent missing"
# Serve via temp launchd job so XPC_SERVICE_NAME is set and Mach works.
plist="$(qa_mktemp)/job.plist"
wp02_start_temp_job "${WP02_STANDALONE_AGENT}" "${plist}" || qa_die "temp job start failed"
wp02_cli get-counter
assert_eq "${WP02_CLI_RC}" "0" "v2 agent reads preserved counter"
assert_contains "${WP02_CLI_OUT}" "OK counter=1" "value preserved after failed downgrade"
wp02_stop_temp_job

qa_pass
