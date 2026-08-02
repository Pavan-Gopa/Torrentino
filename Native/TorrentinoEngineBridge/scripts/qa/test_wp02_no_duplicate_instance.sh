#!/usr/bin/env bash
#
# QA WP-02 — no duplicate instance (flock bail-out) (feature 10).
#
# Verifies:
#   * while a launchd-managed agent holds the lock, a second direct launch
#     exits 0 without disturbing the original;
#   * original pid is unchanged;
#   * after original is gone, a new instance can take the lock (via SMAppService
#     on-demand or re-register).
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"
source "${QA_DIR}/qa_wp02_common.sh"

wp02_require_app
wp02_trap_cleanup
wp02_reset

wp02_register_and_wait || qa_die "register failed"
PID1="$(wp02_agent_pid)"
assert_ne "${PID1}" "" "primary agent pid"

wp02_cli get-counter
assert_eq "${WP02_CLI_RC}" "0" "primary serves XPC"

# --- happy: duplicate direct launch bails out cleanly -----------------------
log="$(qa_mktemp)/dup.log"
set +e
# Direct launch: will take flock, see conflict, exit 0 (before or after
# XPC_SERVICE_NAME check — product takes lock in init first).
"${WP02_AGENT_BIN}" >"${log}" 2>&1
dup_rc=$?
set -e
qa_log "duplicate direct launch rc=${dup_rc}"
body="$(cat "${log}")"
echo "${body}" | while IFS= read -r line; do qa_log "  | ${line}"; done || true

assert_eq "${dup_rc}" "0" "duplicate instance exits 0"
sleep 1
wp02_agent_running || qa_die "primary agent gone after duplicate probe"
PID2="$(wp02_agent_pid)"
assert_eq "${PID2}" "${PID1}" "original pid still running (no takeover)"

# Primary still serves.
wp02_cli hello
assert_eq "${WP02_CLI_RC}" "0" "primary still serves after duplicate"
assert_contains "${WP02_CLI_OUT}" "pid=${PID1}" "hello still from original pid"

# --- edge: after primary clean stop, lock is free for relaunch --------------
wp02_cli shutdown
wp02_wait_for 10 wp02_agent_gone || qa_die "primary did not exit"
sleep 0.5

wp02_cli hello
assert_eq "${WP02_CLI_RC}" "0" "on-demand relaunch after lock released"
PID3="$(wp02_agent_pid)"
assert_ne "${PID3}" "" "new instance after lock free"
assert_ne "${PID3}" "${PID1}" "new pid after lock free"

qa_pass
