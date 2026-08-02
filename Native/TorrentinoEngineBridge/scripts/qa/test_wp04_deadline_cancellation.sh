#!/usr/bin/env bash
#
# QA WP-04 — deadline/cancellation: timeout + shutdown-during-wait.
#
# Verifies: (a) setOperationTimeout → BridgeError::timeout, (b) shutdown during
# a bounded wait → BridgeError::stopped, (c) in-flight waiter returns without
# hanging. Checks both static coverage in bridge_smoke.cpp and runtime via
# the headless test.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

BRIDGE_H="${BRIDGE_DIR}/bridge/EngineBridge.h"
BRIDGE_SMOKE="${BRIDGE_DIR}/bridge/bridge_smoke.cpp"

assert_file "${BRIDGE_H}"      "EngineBridge.h exists"
assert_file "${BRIDGE_SMOKE}"  "bridge_smoke.cpp exists"

BRIDGE_H_CONTENT="$(cat "${BRIDGE_H}")"
SMOKE_CONTENT="$(cat "${BRIDGE_SMOKE}")"

# --- setOperationTimeout API exists and is noexcept ---------------------------
assert_contains "${BRIDGE_H_CONTENT}" "setOperationTimeout" \
	"setOperationTimeout declared in header"

# --- BridgeError::timeout is in the taxonomy ----------------------------------
assert_contains "${BRIDGE_H_CONTENT}" "timeout = 4" \
	"BridgeError::timeout defined"

# --- BridgeError::stopped is in the taxonomy ----------------------------------
assert_contains "${BRIDGE_H_CONTENT}" "stopped = 8" \
	"BridgeError::stopped defined"

# --- bridge_smoke tests deadline: setOperationTimeout(1) → timeout -----------
assert_contains "${SMOKE_CONTENT}" "setOperationTimeout(1)" \
	"smoke sets a 1ms deadline to trigger timeout"
assert_contains "${SMOKE_CONTENT}" "BridgeError::timeout" \
	"smoke asserts BridgeError::timeout on expired deadline"
assert_contains "${SMOKE_CONTENT}" "expired deadline maps to BridgeError::timeout" \
	"smoke documents the deadline-to-timeout mapping"

# --- bridge_smoke tests cancellation: shutdown during requestResumeData -------
assert_contains "${SMOKE_CONTENT}" "BridgeError::stopped" \
	"smoke asserts BridgeError::stopped on shutdown-during-wait"
assert_contains "${SMOKE_CONTENT}" "shutdown during a bounded wait" \
	"smoke documents cancellation semantics"
assert_contains "${SMOKE_CONTENT}" "in-flight requestResumeData returns after shutdown" \
	"smoke asserts waiter unblocks (no hang)"

# --- The cancellation test uses a separate engine + thread --------------------
assert_contains "${SMOKE_CONTENT}" "std::thread waiter" \
	"cancellation test uses a dedicated waiter thread"
assert_contains "${SMOKE_CONTENT}" "std::atomic<bool> finished" \
	"cancellation test uses atomic finished flag"

# --- Bounded join: the waiter must return within a deadline -------------------
assert_contains "${SMOKE_CONTENT}" "Bounded join" \
	"cancellation test has a bounded join (no infinite wait)"

# --- Run the headless test to prove deadline + cancellation at runtime --------
HEADLESS_SH="${SCRIPTS_DIR}/test_bridge_headless.sh"
assert_file "${HEADLESS_SH}" "test_bridge_headless.sh present"

LOG="$(qa_mktemp)/deadline.log"
set +e
bash "${HEADLESS_SH}" 2>&1 | tee "${LOG}"
rc=${PIPESTATUS[0]}
set -e

[[ ${rc} -eq 0 ]] || qa_die "headless test failed (deadline/cancellation broken); see ${LOG}"
assert_contains "$(cat "${LOG}")" "bridge smoke: PASS" "deadline/cancellation: headless passes"

qa_pass
