#!/usr/bin/env bash
#
# QA WP-04 — alert batching: drainAlerts(maxCount) respects the batch bound.
#
# Verifies: (a) drainAlerts accepts a maxCount parameter in both C++ and Swift,
# (b) bridge_smoke tests that an identical second drain returns an empty batch,
# (c) the adapter payload format {\"max-count\": N} is correct.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

BRIDGE_H="${BRIDGE_DIR}/bridge/EngineBridge.h"
BRIDGE_SMOKE="${BRIDGE_DIR}/bridge/bridge_smoke.cpp"
ADAPTER_H="${BRIDGE_DIR}/adapter/EngineBridgeAdapter.h"
COORDINATOR_SWIFT="${NATIVE_DIR}/TorrentinoEngineAgent/EngineCoordinator/EngineCoordinator.swift"

assert_file "${BRIDGE_H}"          "EngineBridge.h exists"
assert_file "${BRIDGE_SMOKE}"      "bridge_smoke.cpp exists"
assert_file "${ADAPTER_H}"         "EngineBridgeAdapter.h exists"
assert_file "${COORDINATOR_SWIFT}" "EngineCoordinator.swift exists"

BRIDGE_H_CONTENT="$(cat "${BRIDGE_H}")"
SMOKE_CONTENT="$(cat "${BRIDGE_SMOKE}")"
ADAPTER_H_CONTENT="$(cat "${ADAPTER_H}")"
COORD_CONTENT="$(cat "${COORDINATOR_SWIFT}")"

# --- C++ drainAlerts accepts max_count parameter ------------------------------
assert_contains "${BRIDGE_H_CONTENT}" "drainAlerts(std::size_t max_count)" \
	"drainAlerts takes max_count parameter in C++"

# --- drainAlerts returns a vector (batch, not one-at-a-time) ------------------
assert_contains "${BRIDGE_H_CONTENT}" "std::vector<EngineAlertDTO> drainAlerts" \
	"drainAlerts returns vector (batch semantics)"

# --- drainAlerts is noexcept (exception firewall) ----------------------------
assert_contains "${BRIDGE_H_CONTENT}" "drainAlerts(std::size_t max_count) noexcept" \
	"drainAlerts is noexcept"

# --- bridge_smoke tests drain-batch semantics (second drain = empty) ----------
assert_contains "${SMOKE_CONTENT}" "drain-batch semantics" \
	"smoke tests drain-batch semantics"
assert_contains "${SMOKE_CONTENT}" "second drain returns empty batch" \
	"smoke asserts second drain is empty"

# --- Adapter accepts {\"max-count\": N} payload ---------------------------------
assert_contains "${ADAPTER_H_CONTENT}" "max-count" \
	"adapter documents max-count payload key"

# --- Swift EngineCoordinator drainAlerts has maxCount parameter ----------------
assert_contains "${COORD_CONTENT}" "func drainAlerts(maxCount:" \
	"Swift drainAlerts accepts maxCount parameter"

# --- Swift uses AlertDrainPayload with max-count key -------------------------
assert_contains "${COORD_CONTENT}" "AlertDrainPayload(maxCount:" \
	"Swift creates AlertDrainPayload"
assert_contains "${COORD_CONTENT}" 'case maxCount = "max-count"' \
	"AlertDrainPayload encodes to max-count key"

# --- Run headless to confirm drain behavior at runtime -----------------------
HEADLESS_SH="${SCRIPTS_DIR}/test_bridge_headless.sh"
assert_file "${HEADLESS_SH}" "test_bridge_headless.sh present"

LOG="$(qa_mktemp)/alert-batch.log"
set +e
bash "${HEADLESS_SH}" 2>&1 | tee "${LOG}"
rc=${PIPESTATUS[0]}
set -e

[[ ${rc} -eq 0 ]] || qa_die "headless test failed (alert batching broken); see ${LOG}"
assert_contains "$(cat "${LOG}")" "bridge smoke: PASS" "alert batching: headless passes"

qa_pass
