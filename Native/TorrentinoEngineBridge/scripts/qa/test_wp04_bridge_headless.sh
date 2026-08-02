#!/usr/bin/env bash
#
# QA WP-04 — headless lifecycle PASS.
#
# Verifies the full EngineBridge headless lifecycle: start → add → checked →
# pause → resume → recheck → remove → shutdown. Wraps
# test_bridge_headless.sh and asserts PASS + key output markers.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

HEADLESS_SH="${SCRIPTS_DIR}/test_bridge_headless.sh"
assert_file "${HEADLESS_SH}" "test_bridge_headless.sh present"

# --- Run the headless lifecycle test ------------------------------------------
LOG="$(qa_mktemp)/headless.log"
set +e
bash "${HEADLESS_SH}" 2>&1 | tee "${LOG}"
rc=${PIPESTATUS[0]}
set -e

[[ ${rc} -eq 0 ]] || qa_die "test_bridge_headless.sh failed (rc=${rc}); see ${LOG}"

OUTPUT="$(cat "${LOG}")"

# --- Assert key lifecycle stages appeared in the output -----------------------
# bridge_smoke.cpp prints "bridge smoke: PASS" only when g_failures == 0
assert_contains "${OUTPUT}" "bridge smoke: PASS"         "headless lifecycle PASS"

# The adapter compile check must have passed (WP-04 CHANGES_REQUESTED 3-1)
assert_contains "${OUTPUT}" "building bridge adapter"    "adapter compile step ran"

# The result line from test_bridge_headless.sh
assert_contains "${OUTPUT}" "RESULT: PASS"               "headless overall PASS"

qa_pass
