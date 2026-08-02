#!/usr/bin/env bash
#
# QA WP-02 — update_test.sh meta-gate (feature 8).
#
# Verifies:
#   * Native/Config/update_test.sh exists and is executable;
#   * full script exits 0 with PASS=26 FAIL=0 (v1→v2 migration, downgrade,
#     corruption);
#   * evidence artifacts written;
#   * no residual launchd job / agent after exit.
#
# Note: this rebuilds v1+v2 agents — long-running by design.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"
source "${QA_DIR}/qa_wp02_common.sh"

wp02_require_app
wp02_trap_cleanup

assert_file "${WP02_UPDATE_SH}" "update_test.sh present"
[[ -x "${WP02_UPDATE_SH}" ]] || qa_die "update_test.sh not executable"
qa_ok "update_test.sh executable"

check_count="$(grep -c 'check "' "${WP02_UPDATE_SH}" || true)"
assert_eq "${check_count}" "26" "update_test.sh defines 26 checks"

OUT_DIR="$(qa_mktemp)/update-out"
mkdir -p "${OUT_DIR}"
export OUT_DIR

qa_log "running update_test.sh (builds v1+v2 — may take several minutes)"
set +e
bash "${WP02_UPDATE_SH}" >"${OUT_DIR}/runner.log" 2>&1
up_rc=$?
set -e
tail -40 "${OUT_DIR}/runner.log" || true

assert_eq "${up_rc}" "0" "update_test.sh exit 0"
assert_file "${OUT_DIR}/EVIDENCE.md" "EVIDENCE.md written"
ev="$(cat "${OUT_DIR}/EVIDENCE.md")"
assert_contains "${ev}" "PASS=26" "PASS=26 in evidence"
assert_contains "${ev}" "FAIL=0" "FAIL=0 in evidence"
assert_contains "${ev}" "v2.value_preserved" "migration check present"
assert_contains "${ev}" "downgrade.exit_78" "downgrade check present"
assert_contains "${ev}" "corrupt.exit_1" "corruption check present"

# Residual cleanup verification.
wp02_cleanup
sleep 0.5
set +e
launchctl print "${WP02_DOMAIN}/${WP02_LABEL}" >/dev/null 2>&1
print_rc=$?
set -e
assert_ne "${print_rc}" "0" "no residual launchd job"
wp02_agent_running && qa_die "residual agent process" || qa_ok "no residual agent"
[[ ! -d "${WP02_ENGINE_DIR}" ]] || qa_die "engine dir residual"
qa_ok "engine dir wiped after update_test"

qa_pass
