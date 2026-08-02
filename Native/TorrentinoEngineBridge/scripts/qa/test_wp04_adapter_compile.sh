#!/usr/bin/env bash
#
# QA WP-04 — adapter compile check: ObjC++ compiles, JSON envelopes, NSError mapping.
#
# Verifies the EngineBridgeAdapter ObjC++ layer: compiles under -Werror, uses
# the correct error domain and codes, and all methods use JSON NSData envelopes.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

ADAPTER_H="${BRIDGE_DIR}/adapter/EngineBridgeAdapter.h"
ADAPTER_MM="${BRIDGE_DIR}/adapter/EngineBridgeAdapter.mm"
HEADLESS_SH="${SCRIPTS_DIR}/test_bridge_headless.sh"

assert_file "${ADAPTER_H}"    "adapter header exists"
assert_file "${ADAPTER_MM}"   "adapter implementation exists"
assert_file "${HEADLESS_SH}"  "test_bridge_headless.sh present (does adapter compile)"

ADAPTER_H_CONTENT="$(cat "${ADAPTER_H}")"
ADAPTER_MM_CONTENT="$(cat "${ADAPTER_MM}")"

# --- Error domain must be defined correctly -----------------------------------
assert_contains "${ADAPTER_H_CONTENT}" "TorrentinoEngineBridgeErrorDomain" \
	"error domain declared in header"
assert_contains "${ADAPTER_MM_CONTENT}" "TorrentinoEngineBridgeErrorDomain" \
	"error domain defined in implementation"

# --- NSError codes mirror BridgeError taxonomy (all 9 non-zero cases) ---------
for code in NotStarted AlreadyStarted NotFound Timeout InvalidArgument EngineFailure IO Stopped Internal; do
	assert_contains "${ADAPTER_H_CONTENT}" "TorrentinoEngineBridgeError${code}" \
		"NS_ENUM code TorrentinoEngineBridgeError${code} declared"
done

# --- Adapter uses NSJSONSerialization or similar for JSON envelopes -----------
json_usage="$(echo "${ADAPTER_MM_CONTENT}" | grep -cE 'NSJSONSerialization|JSONSerialization|NSJSONWriting|NSJSONReading|jsonDataWith|dataWithJSON' || true)"
assert_ge "${json_usage}" "1" "adapter uses JSON serialization"

# --- Adapter creates NSError with userInfo for failure messages ---------------
nserror_creation="$(echo "${ADAPTER_MM_CONTENT}" | grep -cE 'NSError|NSLocalizedDescriptionKey|errorWithDomain|userInfo' || true)"
assert_ge "${nserror_creation}" "3" "adapter creates NSError with localizedDescription"

# --- Compile check: headless test includes adapter build step -----------------
LOG="$(qa_mktemp)/adapter-compile.log"
set +e
bash "${HEADLESS_SH}" 2>&1 | tee "${LOG}"
rc=${PIPESTATUS[0]}
set -e

OUTPUT="$(cat "${LOG}")"
assert_contains "${OUTPUT}" "building bridge adapter" \
	"headless script builds the adapter"
[[ ${rc} -eq 0 ]] || qa_die "adapter compile check failed (rc=${rc}); see ${LOG}"
assert_contains "${OUTPUT}" "RESULT: PASS" "adapter compile + link succeeded"

qa_pass
