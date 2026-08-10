#!/usr/bin/env bash
#
# QA WP-03 — TorrentState / TorrentInfo / EngineError unit coverage.
#
# Static source contracts + XCTest Domain target (happy / error / edge).
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

STATE_SWIFT="${NATIVE_DIR}/TorrentinoDomain/TorrentState.swift"
INFO_SWIFT="${NATIVE_DIR}/TorrentinoDomain/TorrentInfo.swift"
ERROR_SWIFT="${NATIVE_DIR}/TorrentinoDomain/EngineError.swift"
TESTS_SWIFT="${NATIVE_DIR}/Tests/TorrentinoDomainTests/TorrentinoDomainTests.swift"
XCODEPROJ="${NATIVE_DIR}/Torrentino.xcodeproj"
LOG="$(qa_mktemp)/domain-xctest.log"

assert_file "${STATE_SWIFT}" "TorrentState.swift"
assert_file "${INFO_SWIFT}" "TorrentInfo.swift"
assert_file "${ERROR_SWIFT}" "EngineError.swift"
assert_file "${TESTS_SWIFT}" "TorrentinoDomainTests.swift"

STATE="$(cat "${STATE_SWIFT}")"
INFO="$(cat "${INFO_SWIFT}")"
ERR="$(cat "${ERROR_SWIFT}")"
TESTS="$(cat "${TESTS_SWIFT}")"

# --- TorrentState public surface -------------------------------------------
for case in queued downloading seeding paused error stopped; do
	assert_contains "${STATE}" "case ${case}" "TorrentState.${case}"
done
assert_contains "${STATE}" "Codable" "TorrentState Codable"
assert_contains "${STATE}" "Sendable" "TorrentState Sendable"
assert_contains "${STATE}" "CaseIterable" "TorrentState CaseIterable"

# --- TorrentInfo public surface --------------------------------------------
for field in id name size progress state; do
	assert_contains "${INFO}" "public let ${field}" "TorrentInfo.${field}"
done
assert_contains "${INFO}" "Sendable" "TorrentInfo Sendable"
assert_contains "${INFO}" "Codable" "TorrentInfo Codable"

# --- EngineError public surface --------------------------------------------
for case in xpcUnavailable agentDenied timeout internalError; do
	assert_contains "${ERR}" "case ${case}" "EngineError.${case}"
done
assert_contains "${ERR}" "Error" "EngineError Error"
assert_contains "${ERR}" "Sendable" "EngineError Sendable"

# LocalizedError is required by kick / ADR UI contract — detect absence.
if ! grep -q 'LocalizedError' "${ERROR_SWIFT}"; then
	qa_log "DETECT: EngineError does not declare LocalizedError (product gap)"
fi

# --- Unit tests must cover ADR-010 axes ------------------------------------
assert_contains "${TESTS}" "testTorrentStateCodableRoundTrip" "state Codable test"
assert_contains "${TESTS}" "testTorrentInfoCodableRoundTrip" "info Codable test"
assert_contains "${TESTS}" "testTorrentInfoEdgeEmptyNameSizeZeroProgressBounds" "info edge test"
assert_contains "${TESTS}" "testEngineError" "engine error tests"
assert_contains "${TESTS}" "testTorrentStateSendableConcurrentReads" "concurrency stress"
assert_contains "${TESTS}" "testTorrentInfoTamperedJSONDecodeFails" "negative/fuzz"
qa_log "priming the app product before the focused target (Xcode cold dependency-order workaround)…"
set +e
xcodebuild build \
	-project "${XCODEPROJ}" \
	-scheme Torrentino \
	-destination 'platform=macOS,arch=arm64' \
	CODE_SIGN_IDENTITY="Developer ID Application" \
	DEVELOPMENT_TEAM=438UQRF7JV \
	2>&1 | tee "${LOG}"
prime_rc=${PIPESTATUS[0]}
set -e
[[ ${prime_rc} -eq 0 ]] || qa_die "app product priming failed (rc=${prime_rc}); see ${LOG}"


qa_log "running TorrentinoDomainTests…"
set +e
xcodebuild test \
	-project "${XCODEPROJ}" \
	-scheme Torrentino \
	-destination 'platform=macOS,arch=arm64' \
	-only-testing:TorrentinoDomainTests \
	CODE_SIGN_IDENTITY="Developer ID Application" \
	DEVELOPMENT_TEAM=438UQRF7JV \
	2>&1 | tee -a "${LOG}"
rc=${PIPESTATUS[0]}
set -e

# LocalizedError assertion is intentional product-contract probe.
if grep -q 'LocalizedError' "${LOG}" && grep -qiE 'XCTAssertTrue failed|failed - EngineError must conform' "${LOG}"; then
	qa_die "EngineError missing LocalizedError conformance (Domain unit test failed)"
fi

[[ ${rc} -eq 0 ]] || {
	grep -E 'error:|failed|XCTAssert|TEST FAILED' "${LOG}" | tail -n 60 >&2 || true
	qa_die "TorrentinoDomainTests failed (rc=${rc})"
}

qa_ok "domain types unit coverage green"
qa_pass
