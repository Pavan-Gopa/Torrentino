#!/usr/bin/env bash
#
# QA WP-02 — Mach XPC hello/health/counter protocol (feature 2).
#
# Verifies:
#   * 5 wire methods round-trip with typed replies (hello/health/increment/
#     get-counter/shutdown);
#   * health payload carries format/machService/counter keys;
#   * invalidation / unreachable when agent is not registered → CLI exit 2;
#   * unknown CLI command → usage (exit 1).
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"
source "${QA_DIR}/qa_wp02_common.sh"

wp02_require_app
wp02_trap_cleanup
wp02_reset

# --- error: no agent → XPC invalidation / unavailable -----------------------
wp02_cli hello
assert_eq "${WP02_CLI_RC}" "2" "hello without agent exits 2 (unreachable)"
assert_contains "${WP02_CLI_OUT}" "FAIL hello" "hello fails when agent absent"

wp02_cli get-counter
assert_eq "${WP02_CLI_RC}" "2" "get-counter without agent exits 2"

# --- error: unknown command -------------------------------------------------
set +e
usage_out="$("${WP02_CLI}" --cli "not-a-command" 2>&1)"
usage_rc=$?
set -e
assert_eq "${usage_rc}" "1" "unknown cli command exits 1"
assert_contains "${usage_out}" "usage:" "unknown command prints usage"

# --- happy: register then all 5 methods -------------------------------------
wp02_register_and_wait || qa_die "register+spawn failed"
PID="$(wp02_agent_pid)"

wp02_cli hello
assert_eq "${WP02_CLI_RC}" "0" "hello exit 0"
assert_match "${WP02_CLI_OUT}" "OK hello version=1\.0\.0-wp02-v2 pid=${PID}" "hello typed reply"

wp02_cli health
assert_eq "${WP02_CLI_RC}" "0" "health exit 0"
assert_contains "${WP02_CLI_OUT}" "OK health" "health OK prefix"
assert_contains "${WP02_CLI_OUT}" "format=v2" "health counterFormat=v2"
assert_contains "${WP02_CLI_OUT}" "version=1.0.0-wp02-v2" "health agentVersion"
assert_contains "${WP02_CLI_OUT}" "counter=" "health counter field"
# Wire contract carries machService in the dict; CLI summary prints format/version/pid/counter.
assert_contains "$(cat "${NATIVE_DIR}/TorrentinoEngineAgent/XPC/TorrentinoEngineXPCProtocol.swift")" \
	"machServiceName = \"${WP02_MACH}\"" "protocol freezes mach service name"

wp02_cli increment
assert_eq "${WP02_CLI_RC}" "0" "increment exit 0"
assert_contains "${WP02_CLI_OUT}" "counter=1" "increment → 1"

wp02_cli get-counter
assert_eq "${WP02_CLI_RC}" "0" "get-counter exit 0"
assert_contains "${WP02_CLI_OUT}" "OK counter=1" "get-counter authoritative"

wp02_cli shutdown
assert_eq "${WP02_CLI_RC}" "0" "shutdown exit 0"
assert_contains "${WP02_CLI_OUT}" "acknowledged=true" "shutdown ack true"
wp02_wait_for 10 wp02_agent_gone || qa_die "agent still alive after shutdown"

# --- edge: after clean shutdown, on-demand Mach relaunch via hello ----------
wp02_cli hello
assert_eq "${WP02_CLI_RC}" "0" "hello after clean stop (on-demand relaunch)"
assert_contains "${WP02_CLI_OUT}" "OK hello" "on-demand hello OK"
PID2="$(wp02_agent_pid)"
assert_ne "${PID2}" "" "new agent pid after on-demand"
assert_ne "${PID2}" "${PID}" "on-demand pid differs from pre-shutdown"

qa_pass
