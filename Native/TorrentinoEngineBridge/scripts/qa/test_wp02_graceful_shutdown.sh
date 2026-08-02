#!/usr/bin/env bash
#
# QA WP-02 — graceful shutdown (SIGTERM / XPC shutdown → exit 0) (feature 5).
#
# Verifies:
#   * XPC shutdown acks, process exits, last exit code = 0;
#   * counter is flushed (get after on-demand relaunch returns pre-shutdown value);
#   * SIGTERM path also exits 0;
#   * KeepAlive.SuccessfulExit=false: clean exit does NOT immediately respawn
#     without a Mach message (agent stays gone until on-demand).
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"
source "${QA_DIR}/qa_wp02_common.sh"

wp02_require_app
wp02_trap_cleanup
wp02_reset

wp02_register_and_wait || qa_die "register failed"

wp02_cli increment; assert_contains "${WP02_CLI_OUT}" "counter=1" "inc 1"
wp02_cli increment; assert_contains "${WP02_CLI_OUT}" "counter=2" "inc 2"

# --- XPC shutdown path ------------------------------------------------------
wp02_cli shutdown
assert_eq "${WP02_CLI_RC}" "0" "shutdown CLI exit 0"
assert_contains "${WP02_CLI_OUT}" "acknowledged=true" "shutdown ack"
wp02_wait_for 10 wp02_agent_gone || qa_die "agent still running after XPC shutdown"
qa_ok "process exited after XPC shutdown"

# Give launchd a moment to record last exit code.
sleep 1
LEX="$(wp02_last_exit_code)"
qa_log "last exit code after XPC shutdown: ${LEX:-<none>}"
assert_eq "${LEX}" "0" "XPC shutdown last exit code = 0"

# Clean exit must NOT auto-respawn without Mach demand (SuccessfulExit=false).
sleep 2
wp02_agent_running && qa_die "agent auto-respawned after clean exit (KeepAlive bug)" || qa_ok "no auto-respawn after clean exit"

# On-demand relaunch preserves flushed counter.
wp02_cli get-counter
assert_eq "${WP02_CLI_RC}" "0" "on-demand get-counter after XPC stop"
assert_contains "${WP02_CLI_OUT}" "OK counter=2" "counter flushed across clean stop"

PID_SIG="$(wp02_agent_pid)"
assert_ne "${PID_SIG}" "" "agent running after on-demand"

# --- SIGTERM path -----------------------------------------------------------
kill -TERM "${PID_SIG}"
wp02_wait_for 10 wp02_agent_gone || qa_die "agent still running after SIGTERM"
sleep 1
LEX="$(wp02_last_exit_code)"
qa_log "last exit code after SIGTERM: ${LEX:-<none>}"
assert_eq "${LEX}" "0" "SIGTERM last exit code = 0"

# Counter still durable after signal-path stop.
wp02_cli get-counter
assert_eq "${WP02_CLI_RC}" "0" "get-counter after SIGTERM"
assert_contains "${WP02_CLI_OUT}" "OK counter=2" "counter durable after SIGTERM"

qa_pass
