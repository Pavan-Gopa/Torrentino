#!/usr/bin/env bash
#
# QA WP-04 — TorrentIDPayload: pause/resume/recheck encode torrent id.
#
# Verifies the reviewer's bug 3-3 fix: pause, resume, and recheck all use
# TorrentIDPayload that encodes the actual torrent id (not an empty payload).
# Checks both the static code contract and the runtime Swift bridge test.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

COORDINATOR_SWIFT="${NATIVE_DIR}/TorrentinoEngineAgent/EngineCoordinator/EngineCoordinator.swift"
SWIFT_HARNESS="${BRIDGE_DIR}/harness/bridge_swift_test.swift"

assert_file "${COORDINATOR_SWIFT}" "EngineCoordinator.swift exists"
assert_file "${SWIFT_HARNESS}"     "bridge_swift_test.swift exists"

COORD_CONTENT="$(cat "${COORDINATOR_SWIFT}")"
HARNESS_CONTENT="$(cat "${SWIFT_HARNESS}")"

# --- pause/resume/recheck all use TorrentIDPayload with torrentID parameter --
assert_contains "${COORD_CONTENT}" "func pause(torrentID: String)" \
	"pause takes torrentID parameter"
assert_contains "${COORD_CONTENT}" "func resume(torrentID: String)" \
	"resume takes torrentID parameter"
assert_contains "${COORD_CONTENT}" "func recheck(torrentID: String)" \
	"recheck takes torrentID parameter"

# --- Each method encodes a TorrentIDPayload (not empty data) ------------------
# Count uses of TorrentIDPayload in the three methods (should be >= 3)
payload_uses="$(echo "${COORD_CONTENT}" | grep -c 'TorrentIDPayload(torrentID:' || true)"
assert_ge "${payload_uses}" "3" "pause/resume/recheck all create TorrentIDPayload with torrentID"

# --- TorrentIDPayload has CodingKeys with torrent-id key ----------------------
assert_contains "${COORD_CONTENT}" 'case torrentID = "torrent-id"' \
	"TorrentIDPayload encodes to kebab-case torrent-id"

# --- Swift harness exercises pause/resume/recheck with real torrent id --------
assert_contains "${HARNESS_CONTENT}" "coordinator.pause(torrentID: torrentID)" \
	"harness calls pause with torrentID"
assert_contains "${HARNESS_CONTENT}" "coordinator.resume(torrentID: torrentID)" \
	"harness calls resume with torrentID"
assert_contains "${HARNESS_CONTENT}" "coordinator.recheck(torrentID: torrentID)" \
	"harness calls recheck with torrentID"

# --- Negative test: unknown id must return notFound (proves id reaches engine) -
assert_contains "${HARNESS_CONTENT}" "pause of an unknown id must throw notFound" \
	"harness tests unknown-id → notFound"
assert_contains "${HARNESS_CONTENT}" "EngineCoordinatorError.notFound" \
	"harness catches notFound error"

# --- Run Swift bridge test to prove torrent-id round-trip at runtime ----------
SWIFT_TEST_SH="${SCRIPTS_DIR}/test_bridge_swift.sh"
assert_file "${SWIFT_TEST_SH}" "test_bridge_swift.sh present"

LOG="$(qa_mktemp)/torrent-id.log"
set +e
bash "${SWIFT_TEST_SH}" 2>&1 | tee "${LOG}"
rc=${PIPESTATUS[0]}
set -e

[[ ${rc} -eq 0 ]] || qa_die "Swift bridge test failed (torrent-id payload broken); see ${LOG}"
assert_contains "$(cat "${LOG}")" "RESULT: PASS" "torrent-id payload: Swift test passes"

qa_pass
