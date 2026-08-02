#!/usr/bin/env bash
#
# QA WP-04 — deterministic shutdown: double shutdown OK, idempotent.
#
# Verifies shutdown() is noexcept, idempotent (double shutdown not crash), joins
# threads, and health reports stopped after shutdown. Checks both static code
# contracts and runtime behavior through bridge_smoke.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

BRIDGE_H="${BRIDGE_DIR}/bridge/EngineBridge.h"
BRIDGE_SMOKE="${BRIDGE_DIR}/bridge/bridge_smoke.cpp"

assert_file "${BRIDGE_H}"      "EngineBridge.h exists"
assert_file "${BRIDGE_SMOKE}"  "bridge_smoke.cpp exists"

BRIDGE_H_CONTENT="$(cat "${BRIDGE_H}")"
SMOKE_CONTENT="$(cat "${BRIDGE_SMOKE}")"

# --- shutdown() is noexcept (contract) ----------------------------------------
assert_contains "${BRIDGE_H_CONTENT}" "void shutdown() noexcept" \
	"shutdown() declared noexcept in header"

# --- shutdown() is called twice in bridge_smoke (idempotence test) ------------
shutdown_calls="$(echo "${SMOKE_CONTENT}" | grep -c 'bridge\.shutdown()' || true)"
assert_ge "${shutdown_calls}" "2" "bridge_smoke calls shutdown() at least 2 times (idempotence)"

# --- bridge_smoke asserts health.running == false after shutdown ---------------
assert_contains "${SMOKE_CONTENT}" "health reports stopped engine" \
	"smoke asserts engine stopped after shutdown"

# --- bridge_smoke includes the \"shutdown + idempotence\" section ---------------
assert_contains "${SMOKE_CONTENT}" "shutdown + idempotence" \
	"smoke has dedicated shutdown-idempotence section"

# --- The second shutdown must be documented as a no-op, not crash -------------
assert_contains "${SMOKE_CONTENT}" "must be a no-op, not a crash" \
	"double shutdown documented as safe no-op"

# --- Run the headless test to prove shutdown idempotence at runtime -----------
HEADLESS_SH="${SCRIPTS_DIR}/test_bridge_headless.sh"
assert_file "${HEADLESS_SH}" "test_bridge_headless.sh present"

LOG="$(qa_mktemp)/shutdown.log"
set +e
bash "${HEADLESS_SH}" 2>&1 | tee "${LOG}"
rc=${PIPESTATUS[0]}
set -e

[[ ${rc} -eq 0 ]] || qa_die "headless test failed (shutdown idempotence broken); see ${LOG}"
assert_contains "$(cat "${LOG}")" "bridge smoke: PASS" "double shutdown: headless passes"

qa_pass
