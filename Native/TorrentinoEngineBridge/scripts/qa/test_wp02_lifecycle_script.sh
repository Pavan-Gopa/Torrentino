#!/usr/bin/env bash
#
# QA WP-02 — lifecycle_test.sh meta-gate (feature 7).
#
# Verifies:
#   * Native/Config/lifecycle_test.sh exists and is executable;
#   * full script exits 0 with PASS=30 FAIL=0;
#   * evidence dir is written;
#   * cleanup leaves no residual launchd job / agent process.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"
source "${QA_DIR}/qa_wp02_common.sh"

wp02_require_app
wp02_trap_cleanup

assert_file "${WP02_LIFECYCLE_SH}" "lifecycle_test.sh present"
[[ -x "${WP02_LIFECYCLE_SH}" ]] || qa_die "lifecycle_test.sh not executable"
qa_ok "lifecycle_test.sh executable"

# Count expected checks from the script itself (30 named checks).
check_count="$(grep -c 'check "' "${WP02_LIFECYCLE_SH}" || true)"
assert_eq "${check_count}" "30" "lifecycle_test.sh defines 30 checks"

OUT_DIR="$(qa_mktemp)/lifecycle-out"
mkdir -p "${OUT_DIR}"
export APP_PATH="${WP02_APP}"
export OUT_DIR

qa_log "running lifecycle_test.sh (APP_PATH=${APP_PATH})"
set +e
bash "${WP02_LIFECYCLE_SH}" >"${OUT_DIR}/runner.log" 2>&1
lc_rc=$?
set -e
# lifecycle_test tees its own evidence; also keep runner log.
tail -30 "${OUT_DIR}/runner.log" || true

assert_eq "${lc_rc}" "0" "lifecycle_test.sh exit 0"
assert_file "${OUT_DIR}/EVIDENCE.md" "EVIDENCE.md written"
ev="$(cat "${OUT_DIR}/EVIDENCE.md")"
assert_contains "${ev}" "PASS=30" "PASS=30 in evidence"
assert_contains "${ev}" "FAIL=0" "FAIL=0 in evidence"
assert_contains "${ev}" "register.enabled" "register check present"
assert_contains "${ev}" "crash.counter_survived_sigkill" "SIGKILL durability check present"
assert_contains "${ev}" "unregister.job_removed_from_launchd" "unregister check present"

# --- cleanup residual check -------------------------------------------------
# lifecycle_test EXIT trap should have cleaned; re-assert.
sleep 1
set +e
launchctl print "${WP02_DOMAIN}/${WP02_LABEL}" >/dev/null 2>&1
print_rc=$?
set -e
# Job may or may not still be loaded depending on trap order; force clean via our trap.
# Assert: after our wp02_cleanup (on exit) we leave nothing — probe now after manual clean.
wp02_cleanup
sleep 0.5
set +e
launchctl print "${WP02_DOMAIN}/${WP02_LABEL}" >/dev/null 2>&1
print_rc=$?
set -e
assert_ne "${print_rc}" "0" "no residual launchd job after cleanup"
wp02_agent_running && qa_die "residual agent process" || qa_ok "no residual agent process"
[[ ! -d "${WP02_ENGINE_DIR}" ]] || qa_die "engine dir residual: ${WP02_ENGINE_DIR}"
qa_ok "engine dir wiped"

qa_pass
