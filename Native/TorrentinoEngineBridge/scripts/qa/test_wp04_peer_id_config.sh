#!/usr/bin/env bash
#
# QA WP-04 — boot report peer-id from config (not hardcoded).
#
# Verifies reviewer's bug 3-4: the boot report peer-id comes from the
# SessionConfiguration, not from a deprecated session.id() or hardcoded value.
# Checks the static contract and runtime Swift harness (which sets a custom
# prefix and verifies it round-trips).
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

BRIDGE_H="${BRIDGE_DIR}/bridge/EngineBridge.h"
BRIDGE_SMOKE="${BRIDGE_DIR}/bridge/bridge_smoke.cpp"
SWIFT_HARNESS="${BRIDGE_DIR}/harness/bridge_swift_test.swift"

assert_file "${BRIDGE_H}"       "EngineBridge.h exists"
assert_file "${BRIDGE_SMOKE}"   "bridge_smoke.cpp exists"
assert_file "${SWIFT_HARNESS}"  "bridge_swift_test.swift exists"

BRIDGE_H_CONTENT="$(cat "${BRIDGE_H}")"
SMOKE_CONTENT="$(cat "${BRIDGE_SMOKE}")"
HARNESS_CONTENT="$(cat "${SWIFT_HARNESS}")"

# --- SessionConfiguration has peer_id_prefix (configurable) -------------------
assert_contains "${BRIDGE_H_CONTENT}" "peer_id_prefix" \
	"SessionConfiguration has peer_id_prefix field"

# --- BootReport has peer_id field -------------------------------------------
assert_contains "${BRIDGE_H_CONTENT}" "std::string peer_id" \
	"BootReport has peer_id field"

# --- The bridge header documents peer_id as configured, not session.id() -----
assert_contains "${BRIDGE_H_CONTENT}" "configured wire peer-id prefix" \
	"peer_id documented as configured prefix"
assert_contains "${BRIDGE_H_CONTENT}" "not exposed by any" \
	"session.id() documented as not available in 2.x"

# --- Swift harness sets a CUSTOM prefix and checks it round-trips -------------
assert_contains "${HARNESS_CONTENT}" "-TT9001-" \
	"harness uses custom peer-id prefix -TT9001-"
assert_contains "${HARNESS_CONTENT}" 'boot.peerID == "-TT9001-"' \
	"harness asserts boot report peer-id matches config"
assert_contains "${HARNESS_CONTENT}" "boot peer-id must come from config" \
	"harness documents peer-id-from-config contract"

# --- Run the Swift bridge test to prove peer-id round-trip at runtime ---------
SWIFT_TEST_SH="${SCRIPTS_DIR}/test_bridge_swift.sh"
assert_file "${SWIFT_TEST_SH}" "test_bridge_swift.sh present"

LOG="$(qa_mktemp)/peer-id.log"
set +e
bash "${SWIFT_TEST_SH}" 2>&1 | tee "${LOG}"
rc=${PIPESTATUS[0]}
set -e

[[ ${rc} -eq 0 ]] || qa_die "Swift bridge test failed (peer-id not from config); see ${LOG}"
assert_contains "$(cat "${LOG}")" "RESULT: PASS" "peer-id from config: Swift test passes"

qa_pass
