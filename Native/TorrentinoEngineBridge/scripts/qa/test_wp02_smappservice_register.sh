#!/usr/bin/env bash
#
# QA WP-02 — SMAppService register/unregister (feature 1).
#
# Verifies:
#   * register() yields status=enabled and creates a launchd job;
#   * RunAtLoad spawns the agent process;
#   * unregister() yields status=notRegistered and removes the launchd job;
#   * agent process is gone after unregister (no residual instance);
#   * error path: double-unregister is non-fatal (status stays notRegistered).
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"
source "${QA_DIR}/qa_wp02_common.sh"

wp02_require_app
wp02_trap_cleanup
wp02_reset

# --- happy: register --------------------------------------------------------
wp02_cli register
assert_eq "${WP02_CLI_RC}" "0" "register exit 0"
assert_contains "${WP02_CLI_OUT}" "status=enabled" "register reports enabled"
wp02_wait_for 15 wp02_agent_running || qa_die "agent did not spawn after register"
PID1="$(wp02_agent_pid)"
assert_ne "${PID1}" "" "agent pid after register"
qa_ok "launchd job spawned agent pid=${PID1}"

# launchctl can print the job
set +e
launchctl print "${WP02_DOMAIN}/${WP02_LABEL}" >/dev/null 2>&1
print_rc=$?
set -e
assert_eq "${print_rc}" "0" "launchctl print sees registered job"
wp02_mach_endpoint || qa_die "MachServices endpoint missing after register"
qa_ok "Mach service ${WP02_MACH} present"

# --- happy: status while registered ----------------------------------------
wp02_cli status
assert_eq "${WP02_CLI_RC}" "0" "status exit 0 while enabled"
assert_contains "${WP02_CLI_OUT}" "STATUS service=enabled" "status reports enabled"
assert_contains "${WP02_CLI_OUT}" "STATE operational" "status operational with live agent"

# --- happy: unregister ------------------------------------------------------
wp02_cli unregister
assert_eq "${WP02_CLI_RC}" "0" "unregister exit 0"
assert_contains "${WP02_CLI_OUT}" "status=notRegistered" "unregister reports notRegistered"

set +e
launchctl print "${WP02_DOMAIN}/${WP02_LABEL}" >/dev/null 2>&1
print_rc=$?
set -e
assert_ne "${print_rc}" "0" "launchctl print fails after unregister (job removed)"

wp02_wait_for 10 wp02_agent_gone || qa_die "agent still running after unregister"
qa_ok "no residual agent process after unregister"

# --- edge: double unregister stays notRegistered ----------------------------
wp02_cli unregister
# SMAppService.unregister on already-unregistered may throw or succeed;
# either way status must end notRegistered and CLI must not crash the app.
wp02_cli status
assert_contains "${WP02_CLI_OUT}" "STATUS service=notRegistered" "status notRegistered after double unregister"
assert_contains "${WP02_CLI_OUT}" "STATE degraded" "degraded when not registered"

# --- edge: re-register restores job ----------------------------------------
wp02_cli register
assert_eq "${WP02_CLI_RC}" "0" "re-register exit 0"
assert_contains "${WP02_CLI_OUT}" "status=enabled" "re-register enabled"
wp02_wait_for 15 wp02_agent_running || qa_die "agent did not respawn after re-register"
qa_ok "re-register restored launchd job"

wp02_cli unregister
assert_contains "${WP02_CLI_OUT}" "status=notRegistered" "final unregister"

qa_pass
