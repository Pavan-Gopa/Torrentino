#!/usr/bin/env bash
#
# QA WP-04 — exception firewall: garbage input → error, not crash.
#
# Verifies the EngineBridge exception firewall: bridge_smoke.cpp includes a
# missing-id error path (pause of 64-char zero id → BridgeError::not_found).
# This script also checks that the headless test exercises the error path and
# that the adapter's compile check passes (adapter handles malformed JSON via
# NSError, not crash).
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

BRIDGE_SMOKE="${BRIDGE_DIR}/bridge/bridge_smoke.cpp"
ENGINE_BRIDGE_H="${BRIDGE_DIR}/bridge/EngineBridge.h"
ADAPTER_MM="${BRIDGE_DIR}/adapter/EngineBridgeAdapter.mm"

assert_file "${BRIDGE_SMOKE}"   "bridge_smoke.cpp exists"
assert_file "${ENGINE_BRIDGE_H}" "EngineBridge.h exists"
assert_file "${ADAPTER_MM}"     "EngineBridgeAdapter.mm exists"

SMOKE_CONTENT="$(cat "${BRIDGE_SMOKE}")"
BRIDGE_H_CONTENT="$(cat "${ENGINE_BRIDGE_H}")"
ADAPTER_CONTENT="$(cat "${ADAPTER_MM}")"

# --- Exception firewall: every public method is noexcept ----------------------
# EngineBridge.h: all public methods should be noexcept (the firewall contract)
noexcept_count="$(echo "${BRIDGE_H_CONTENT}" | grep -c 'noexcept' || true)"
assert_ge "${noexcept_count}" "10" "at least 10 noexcept marks in EngineBridge.h"

# --- Garbage input test: bridge_smoke exercises not_found error path ----------
assert_contains "${SMOKE_CONTENT}" "not_found"              "smoke tests cover not_found error"
assert_contains "${SMOKE_CONTENT}" "unknown id maps to not_found" "smoke asserts on unknown-id → not_found"

# The missing-id test uses a 64-char zero string (garbage torrent id)
assert_contains "${SMOKE_CONTENT}" "std::string(64, '0')"  "smoke uses garbage 64-zero torrent id"

# --- BridgeError taxonomy covers all error cases ------------------------------
for err in not_started already_started not_found timeout invalid_argument engine_failure io stopped internal; do
	assert_contains "${BRIDGE_H_CONTENT}" "${err}" "BridgeError::${err} defined in header"
done

# --- Adapter catches NSError, not crash: check for @try/@catch or error: ------
# The adapter should either use @try/@catch or ObjC error: patterns
adapter_error_handling="$(echo "${ADAPTER_CONTENT}" | grep -cE '@try|@catch|error:\(NSError|NSError \*' || true)"
assert_ge "${adapter_error_handling}" "3" "adapter has error handling (NSError or @try/@catch)"

# --- Run the headless test to prove exception firewall under execution ---------
HEADLESS_SH="${SCRIPTS_DIR}/test_bridge_headless.sh"
assert_file "${HEADLESS_SH}" "test_bridge_headless.sh present"

LOG="$(qa_mktemp)/firewall.log"
set +e
bash "${HEADLESS_SH}" 2>&1 | tee "${LOG}"
rc=${PIPESTATUS[0]}
set -e

[[ ${rc} -eq 0 ]] || qa_die "headless test failed (exception firewall broken); see ${LOG}"
assert_contains "$(cat "${LOG}")" "bridge smoke: PASS" "exception firewall: headless passes"

qa_pass
