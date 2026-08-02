#!/usr/bin/env bash
#
# QA WP-02 — denial → degraded state, no in-process fallback (feature 11).
#
# Verifies:
#   * after unregister, --cli status reports STATE degraded + service=notRegistered;
#   * exit code is 3 (denied/not-registered);
#   * no TorrentinoEngineAgent process is spawned as an in-process fallback;
#   * XPC ops fail (exit 2) rather than succeeding via any local engine;
#   * source-level: ServiceRegistration / ViewModel never start an in-process engine.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"
source "${QA_DIR}/qa_wp02_common.sh"

wp02_require_app
wp02_trap_cleanup
wp02_reset

# Start from a known-good registered state, then deny.
wp02_register_and_wait || qa_die "register failed"
wp02_cli status
assert_eq "${WP02_CLI_RC}" "0" "status operational when enabled"
assert_contains "${WP02_CLI_OUT}" "STATE operational" "operational before denial"

# --- denial: unregister -----------------------------------------------------
wp02_cli unregister
assert_contains "${WP02_CLI_OUT}" "status=notRegistered" "unregister → notRegistered"
wp02_wait_for 10 wp02_agent_gone || true
# Force-kill any leftover so we know status path does not spawn one.
pkill -f "TorrentinoEngineAgent" 2>/dev/null || true
sleep 0.5

BEFORE_PIDS="$(pgrep -f TorrentinoEngineAgent 2>/dev/null || true)"
assert_eq "${BEFORE_PIDS}" "" "no agent process before status probe"

wp02_cli status
assert_eq "${WP02_CLI_RC}" "3" "status exit 3 when notRegistered"
assert_contains "${WP02_CLI_OUT}" "STATUS service=notRegistered" "status service=notRegistered"
assert_contains "${WP02_CLI_OUT}" "STATE degraded" "STATE degraded on denial"
assert_contains "${WP02_CLI_OUT}" "reason=service-notRegistered" "degraded reason=service-notRegistered"

AFTER_PIDS="$(pgrep -f TorrentinoEngineAgent 2>/dev/null || true)"
assert_eq "${AFTER_PIDS}" "" "status did not spawn agent (no in-process fallback)"

# XPC must fail — no local engine substitute.
wp02_cli hello
assert_eq "${WP02_CLI_RC}" "2" "hello fails when denied (no fallback engine)"
assert_contains "${WP02_CLI_OUT}" "FAIL hello" "hello FAIL when denied"

wp02_cli get-counter
assert_eq "${WP02_CLI_RC}" "2" "get-counter fails when denied"
AFTER2="$(pgrep -f TorrentinoEngineAgent 2>/dev/null || true)"
assert_eq "${AFTER2}" "" "failed XPC did not spawn agent process"

# --- static: no in-process engine fallback in product sources ---------------
SR_REG="${NATIVE_DIR}/TorrentinoApp/EngineClient/ServiceRegistration.swift"
VM="${NATIVE_DIR}/TorrentinoApp/Features/EngineViewModel.swift"
CLI="${NATIVE_DIR}/TorrentinoApp/App/CLIDispatcher.swift"
assert_file "${SR_REG}" "ServiceRegistration.swift"
assert_file "${VM}" "EngineViewModel.swift"

# Must-not language / degraded-only policy present.
assert_contains "$(cat "${SR_REG}")" "in-process" "ServiceRegistration documents no in-process engine"
assert_contains "$(cat "${VM}")" "degraded" "ViewModel degraded banner"
# CLI maps not-enabled to exit 3 / degraded, never spawns agent binary.
assert_contains "$(cat "${CLI}")" "STATE degraded" "CLI prints STATE degraded"
assert_not_contains "$(cat "${CLI}")" "Process(" "CLI does not spawn Process() for engine"
assert_not_contains "$(cat "${CLI}")" "NSTask" "CLI does not use NSTask fallback"

# Contract documents the policy.
assert_contains "$(cat "${WP02_CONTRACT_MD}")" "never triggers an in-process" "contract: denial never in-process fallback"

qa_pass
