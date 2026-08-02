#!/usr/bin/env bash
#
# QA WP-02 — EngineClient bounded reconnect after agent SIGKILL (feature 4).
#
# Verifies:
#   * after kill -9 + throttle, get-counter succeeds (bounded retries);
#   * returned counter is authoritative (pre-kill durable value);
#   * hello reports a new pid (respawn, not zombie);
#   * with agent permanently gone (unregistered + killed) get-counter fails
#     after budget (exit 2), not hang forever.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"
source "${QA_DIR}/qa_wp02_common.sh"

wp02_require_app
wp02_trap_cleanup
wp02_reset

wp02_register_and_wait || qa_die "register failed"
PID1="$(wp02_agent_pid)"

wp02_cli increment; assert_contains "${WP02_CLI_OUT}" "counter=1" "inc 1"
wp02_cli increment; assert_contains "${WP02_CLI_OUT}" "counter=2" "inc 2"
wp02_cli get-counter; assert_contains "${WP02_CLI_OUT}" "OK counter=2" "pre-kill counter=2"

# Crash the agent while SMAppService job remains registered (KeepAlive will
# respawn after ThrottleInterval).
kill -9 "${PID1}"
wp02_wait_for 10 wp02_agent_gone || qa_die "agent not gone after SIGKILL"
qa_log "sleeping 11s for ThrottleInterval before reconnect probe"
sleep 11

# EngineClient: up to 5 attempts with backoff — should reconnect to respawned agent.
start=$(date +%s)
wp02_cli get-counter
elapsed=$(( $(date +%s) - start ))
assert_eq "${WP02_CLI_RC}" "0" "get-counter reconnect exit 0"
assert_contains "${WP02_CLI_OUT}" "OK counter=2" "reconnect returns authoritative counter=2"
qa_ok "reconnect completed in ${elapsed}s (bounded budget)"

wp02_cli hello
assert_eq "${WP02_CLI_RC}" "0" "hello after reconnect"
PID2="$(echo "${WP02_CLI_OUT}" | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1)"
assert_ne "${PID2}" "" "hello reports pid"
assert_ne "${PID2}" "${PID1}" "hello pid is new after kill"

# --- error path: permanent unavailability -----------------------------------
wp02_cli shutdown
wp02_wait_for 10 wp02_agent_gone || true
wp02_cli unregister
launchctl bootout "${WP02_DOMAIN}/${WP02_LABEL}" >/dev/null 2>&1 || true
pkill -f "TorrentinoEngineAgent" 2>/dev/null || true
sleep 0.5

# No job, no agent → EngineClient exhausts retries → exit 2.
start=$(date +%s)
wp02_cli get-counter
elapsed=$(( $(date +%s) - start ))
assert_eq "${WP02_CLI_RC}" "2" "get-counter with no agent exits 2 (unavailable)"
assert_contains "${WP02_CLI_OUT}" "FAIL get-counter" "FAIL line when unavailable"
# Budget is ~7.75s + overhead; must not hang to the 30s CLI timeout.
assert_ge "30" "${elapsed}" "unavailable path finished before CLI hard timeout (${elapsed}s)"
qa_ok "bounded failure in ${elapsed}s (no infinite retry)"

qa_pass
