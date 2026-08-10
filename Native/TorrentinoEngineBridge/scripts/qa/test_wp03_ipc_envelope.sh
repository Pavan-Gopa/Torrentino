#!/usr/bin/env bash
#
# QA WP-03 — IPCEnvelope / IPCVersion / EngineCommand / EngineEvent.
#
# Static contracts + XCTest IPC target (round-trip, version check, negative).
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

ENV_SWIFT="${NATIVE_DIR}/TorrentinoIPC/IPCEnvelope.swift"
VER_SWIFT="${NATIVE_DIR}/TorrentinoIPC/IPCVersion.swift"
CMD_SWIFT="${NATIVE_DIR}/TorrentinoIPC/EngineCommand.swift"
EVT_SWIFT="${NATIVE_DIR}/TorrentinoIPC/EngineEvent.swift"
TESTS_SWIFT="${NATIVE_DIR}/Tests/TorrentinoIPCTests/TorrentinoIPCTests.swift"
XCODEPROJ="${NATIVE_DIR}/Torrentino.xcodeproj"
LOG="$(qa_mktemp)/ipc-xctest.log"

for f in "${ENV_SWIFT}" "${VER_SWIFT}" "${CMD_SWIFT}" "${EVT_SWIFT}" "${TESTS_SWIFT}"; do
	assert_file "${f}" "$(basename "${f}")"
done

ENV="$(cat "${ENV_SWIFT}")"
VER="$(cat "${VER_SWIFT}")"
CMD="$(cat "${CMD_SWIFT}")"
EVT="$(cat "${EVT_SWIFT}")"
TESTS="$(cat "${TESTS_SWIFT}")"

# --- IPCVersion ------------------------------------------------------------
assert_contains "${VER}" "major" "IPCVersion.major"
assert_contains "${VER}" "minor" "IPCVersion.minor"
assert_contains "${VER}" "static let current" "IPCVersion.current"
assert_contains "${VER}" "major: 1" "current major = 1"
assert_contains "${VER}" "minor: 0" "current minor = 0"
assert_contains "${VER}" "Comparable" "IPCVersion Comparable"
assert_contains "${VER}" "Sendable" "IPCVersion Sendable"

# --- IPCEnvelope -----------------------------------------------------------
assert_contains "${ENV}" "struct IPCEnvelope" "IPCEnvelope type"
assert_contains "${ENV}" "isCompatibleWithCurrent" "version compatibility API"
assert_contains "${ENV}" "Codable" "IPCEnvelope Codable"
assert_contains "${ENV}" "Sendable" "IPCEnvelope Sendable"

# --- EngineCommand / EngineEvent -------------------------------------------
for case in hello health increment getCounter shutdown; do
	assert_contains "${CMD}" "case ${case}" "EngineCommand.${case}"
done
assert_contains "${CMD}" "Codable" "EngineCommand Codable"

for case in stateChanged progressUpdated; do
	assert_contains "${EVT}" "case ${case}" "EngineEvent.${case}"
done
assert_contains "${EVT}" "Codable" "EngineEvent Codable"

# --- Tests cover round-trip + negative -------------------------------------
assert_contains "${TESTS}" "testEnvelopeRoundTripHappy" "envelope round-trip"
assert_contains "${TESTS}" "testEnvelopeTamperedPayloadDecodeFails" "tampered payload"
assert_contains "${TESTS}" "testEngineCommandUnknownDecodeFails" "unknown command"
assert_contains "${TESTS}" "testVersionBackwardCompatLogicViaEnvelope" "backward compat"
assert_contains "${TESTS}" "testEnvelopeFuzzTruncatedJSON" "fuzz/negative parser"
assert_contains "${TESTS}" "testEnvelopeConcurrentEncodeDecodeStress" "concurrency stress"
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


qa_log "running TorrentinoIPCTests…"
set +e
xcodebuild test \
	-project "${XCODEPROJ}" \
	-scheme Torrentino \
	-destination 'platform=macOS,arch=arm64' \
	-only-testing:TorrentinoIPCTests \
	CODE_SIGN_IDENTITY="Developer ID Application" \
	DEVELOPMENT_TEAM=438UQRF7JV \
	2>&1 | tee -a "${LOG}"
rc=${PIPESTATUS[0]}
set -e

[[ ${rc} -eq 0 ]] || {
	grep -E 'error:|failed|XCTAssert|TEST FAILED' "${LOG}" | tail -n 60 >&2 || true
	qa_die "TorrentinoIPCTests failed (rc=${rc})"
}

qa_ok "IPC envelope / version / command / event coverage green"
qa_pass
