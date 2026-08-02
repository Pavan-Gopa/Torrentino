#!/usr/bin/env bash
#
# QA WP-02 — durable counter survives kill -9 (feature 3a).
#
# Verifies:
#   * increments persist before reply (atomic write path);
#   * after SIGKILL + launchd respawn, get-counter returns the pre-kill value;
#   * on-disk magic is TTC2 (v2 format).
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"
source "${QA_DIR}/qa_wp02_common.sh"

wp02_require_app
wp02_trap_cleanup
wp02_reset

wp02_register_and_wait || qa_die "register+spawn failed"
PID1="$(wp02_agent_pid)"

wp02_cli increment; assert_contains "${WP02_CLI_OUT}" "counter=1" "inc 1"
wp02_cli increment; assert_contains "${WP02_CLI_OUT}" "counter=2" "inc 2"
wp02_cli increment; assert_contains "${WP02_CLI_OUT}" "counter=3" "inc 3"
wp02_cli get-counter; assert_contains "${WP02_CLI_OUT}" "OK counter=3" "get 3 pre-kill"

assert_file "${WP02_COUNTER}" "counter.dat exists after increments"
MAGIC="$(wp02_counter_magic)"
assert_eq "${MAGIC}" "TTC2" "on-disk magic TTC2 after v2 writes"

# SIGKILL — uncatchable; durable store must survive.
kill -9 "${PID1}"
wp02_wait_for 10 wp02_agent_gone || qa_die "agent still running after SIGKILL"
qa_ok "process gone after SIGKILL"

# ThrottleInterval=10s: wait for KeepAlive crash-respawn window.
qa_log "sleeping 11s for launchd ThrottleInterval respawn"
sleep 11

wp02_cli get-counter
assert_eq "${WP02_CLI_RC}" "0" "get-counter after SIGKILL reconnects"
assert_contains "${WP02_CLI_OUT}" "OK counter=3" "counter survived SIGKILL (authoritative=3)"

PID2="$(wp02_agent_pid)"
assert_ne "${PID2}" "" "respawned agent pid"
assert_ne "${PID2}" "${PID1}" "respawned pid != killed pid"
qa_ok "KeepAlive respawned new agent pid=${PID2}"

# Edge: increment continues from durable value (not reset to 0).
wp02_cli increment
assert_contains "${WP02_CLI_OUT}" "counter=4" "post-respawn increment continues from 3"

qa_pass
