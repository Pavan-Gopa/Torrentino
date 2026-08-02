#!/usr/bin/env bash
#
# QA WP-04 — DTO Codable round-trip + Sendable compliance.
#
# Verifies all Swift DTOs are Codable and Sendable by static analysis of the
# source and by running the Swift bridge integration test (which exercises the
# full EngineCoordinator → adapter → bridge path with real JSON encoding).
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

DTOS_SWIFT="${NATIVE_DIR}/TorrentinoEngineAgent/EngineCoordinator/EngineBridgeDTOs.swift"
COORDINATOR_SWIFT="${NATIVE_DIR}/TorrentinoEngineAgent/EngineCoordinator/EngineCoordinator.swift"
ERROR_SWIFT="${NATIVE_DIR}/TorrentinoEngineAgent/EngineCoordinator/EngineCoordinatorError.swift"

assert_file "${DTOS_SWIFT}"        "EngineBridgeDTOs.swift exists"
assert_file "${COORDINATOR_SWIFT}" "EngineCoordinator.swift exists"
assert_file "${ERROR_SWIFT}"       "EngineCoordinatorError.swift exists"

DTOS_CONTENT="$(cat "${DTOS_SWIFT}")"
COORD_CONTENT="$(cat "${COORDINATOR_SWIFT}")"
ERROR_CONTENT="$(cat "${ERROR_SWIFT}")"

# --- All DTOs must conform to Codable and Sendable ----------------------------
for dto in SessionConfigurationDTO AddSpecificationDTO BootReportDTO AddResultDTO EngineAlertDTO HealthDTO ResumeDataDTO RemovalTokenDTO RemovalResultDTO; do
	assert_contains "${DTOS_CONTENT}" "${dto}" "DTO ${dto} defined"
done

# Verify Codable + Sendable conformance markers
codable_count="$(echo "${DTOS_CONTENT}" | grep -c 'Codable, Sendable' || true)"
assert_ge "${codable_count}" "8" "at least 8 DTOs have Codable, Sendable"

# --- CodingKeys use kebab-case (wire schema frozen) ---------------------------
assert_contains "${DTOS_CONTENT}" '"torrent-id"'    "kebab-case torrent-id key"
assert_contains "${DTOS_CONTENT}" '"peer-id"'       "kebab-case peer-id key"
assert_contains "${DTOS_CONTENT}" '"listen-port"'   "kebab-case listen-port key"
assert_contains "${DTOS_CONTENT}" '"info-hash"'     "kebab-case info-hash key"
assert_contains "${DTOS_CONTENT}" '"total-size"'    "kebab-case total-size key"
assert_contains "${DTOS_CONTENT}" '"download-dir"'  "kebab-case download-dir key"

# --- EngineCoordinator is an actor -------------------------------------------
assert_contains "${COORD_CONTENT}" "public actor EngineCoordinator" \
	"EngineCoordinator is a Swift actor"

# --- EngineCoordinatorError conforms to Sendable + Equatable -----------------
assert_contains "${ERROR_CONTENT}" "Sendable, Equatable" \
	"EngineCoordinatorError is Sendable + Equatable"

# --- Run the Swift bridge test to prove JSON round-trip at runtime ------------
SWIFT_TEST_SH="${SCRIPTS_DIR}/test_bridge_swift.sh"
assert_file "${SWIFT_TEST_SH}" "test_bridge_swift.sh present"

LOG="$(qa_mktemp)/dto-roundtrip.log"
set +e
bash "${SWIFT_TEST_SH}" 2>&1 | tee "${LOG}"
rc=${PIPESTATUS[0]}
set -e

[[ ${rc} -eq 0 ]] || qa_die "Swift bridge test failed (DTO round-trip broken); see ${LOG}"
assert_contains "$(cat "${LOG}")" "RESULT: PASS" "DTO Codable round-trip: Swift test passes"

qa_pass
