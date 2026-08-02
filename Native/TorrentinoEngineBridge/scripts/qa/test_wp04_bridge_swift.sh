#!/usr/bin/env bash
#
# QA WP-04 — Swift bridge integration (EngineCoordinator → adapter → engine).
#
# Proves the WP-04 Swift actor layer end to end: the coordinator's
# pause/resume/recheck carry the torrent id in the JSON payload (the reviewer's
# 3-3 bug), the boot report peer-id comes from the configuration (3-4), and the
# not-found path round-trips an unknown id to the engine. This is the only QA
# test that executes Swift code against the real C++ engine.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

BRIDGE_SCRIPTS="${SCRIPTS_DIR}"
SWIFT_TEST_SH="${BRIDGE_SCRIPTS}/test_bridge_swift.sh"

assert_file "${SWIFT_TEST_SH}" "test_bridge_swift.sh present"

LOG="$(qa_mktemp)/swift-test.log"
set +e
bash "${SWIFT_TEST_SH}" 2>&1 | tee "${LOG}"
rc=${PIPESTATUS[0]}
set -e

[[ ${rc} -eq 0 ]] || qa_die "test_bridge_swift.sh failed (rc=${rc}); see ${LOG}"
assert_contains "$(cat "${LOG}")" "RESULT: PASS" "swift bridge integration passes"

qa_pass
