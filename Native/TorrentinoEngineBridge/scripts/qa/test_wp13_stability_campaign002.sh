#!/usr/bin/env bash
#
# WP-13 ADR-020 Campaign-002 deterministic stability matrix.
# Covers the six new in-process tests added by campaign-002:
#   I3 (×3): RestoreSummary field consistency after success and anomaly
#   I8 (×3): TransferEventBus register/unregister/sinkCount contracts
#
# The I7 (shutdown veto) and I9 (bootstrap) source-contract proofs live in
# test_wp13_stability_i7i9.sh (the in-process seam is BLOCKED-seam; see that
# script for the full explanation).
#
# Runs only XCTest/TestProfile contracts. Never launches the product agent,
# reads Application Support, or reaches the external BitTorrent network.
#
# Campaign: [WP13-STABILITY-TEST-CAMPAIGN-002]
#
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

SCENARIO_ID="WP13-STABILITY-MATRIX-002"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"
DERIVED_DATA="${REPO_ROOT}/build/WP13StabilityMatrix002DerivedData"
WORK_DIR="$(qa_mktemp)"
RESULT_BUNDLE="${WORK_DIR}/WP13StabilityMatrix002.xcresult"
BUILD_LOG="${WORK_DIR}/build002.log"
TEST_LOG="${WORK_DIR}/test002.log"
ARTIFACT_ROOT="${QA_DIR}/artifacts/${SCENARIO_ID}"
phase=0

phase_marker() {
    phase=$((phase + 1))
    printf 'SCENARIO %s PHASE %02d %s\n' "${SCENARIO_ID}" "${phase}" "$1"
}

preserve_failure() {
    local rc="$1"
    local destination="${ARTIFACT_ROOT}/$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "${destination}"
    for source in "${BUILD_LOG}" "${TEST_LOG}"; do
        if [[ -f "${source}" ]]; then
            local name
            name="$(basename "${source}")"
            sed -E \
                -e 's#/Users/[^/[:space:]]+#/Users/<redacted>#g' \
                -e 's/(password|token|passkey|authorization)[=:][^[:space:]]+/\1=<redacted>/Ig' \
                "${source}" > "${destination}/${name%.log}.redacted.log"
            tail -n 200 "${destination}/${name%.log}.redacted.log" > "${destination}/${name%.log}.redacted.window.log"
        fi
    done
    if [[ -d "${RESULT_BUNDLE}" ]]; then
        cp -R "${RESULT_BUNDLE}" "${destination}/"
    fi
    printf 'SCENARIO %s FAILURE rc=%s artifacts=%s\n' "${SCENARIO_ID}" "${rc}" "${destination}" >&2
}

on_exit() {
    local rc=$?
    if [[ ${rc} -ne 0 ]]; then
        preserve_failure "${rc}"
    fi
    qa_cleanup
    exit "${rc}"
}
trap on_exit EXIT

phase_marker "PREPARE disposable TestProfile-only gate"
rm -rf "${RESULT_BUNDLE}"

phase_marker "BUILD prime known test-target dependency order"
set +e
xcodebuild build \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "${DERIVED_DATA}" \
    2>&1 | tee "${BUILD_LOG}"
build_rc=${PIPESTATUS[0]}
set -e
[[ ${build_rc} -eq 0 ]] || exit "${build_rc}"

phase_marker "EXECUTE six campaign-002 matrix contracts (I3 + I8)"
set +e
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "${DERIVED_DATA}" \
    -resultBundlePath "${RESULT_BUNDLE}" \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testWP13C002I3RestoreSummarySuccessFieldsConsistent \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testWP13C002I3RestoreSummaryAnomalyFieldsConsistent \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testWP13C002I3RestoreSummaryCountsAreConsistent \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testWP13C002I8EventBusRegisterAndUnregisterMaintainsCount \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testWP13C002I8EventBusSameIDReplacesExistingSink \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testWP13C002I8EventBusUnregisterNeverRegisteredIsNoop \
    2>&1 | tee "${TEST_LOG}"
test_rc=${PIPESTATUS[0]}
set -e
[[ ${test_rc} -eq 0 ]] || exit "${test_rc}"

phase_marker "VERIFY exact result count and zero failures"
SUMMARY_JSON="$(xcrun xcresulttool get test-results summary --path "${RESULT_BUNDLE}" --format json)"
COUNTS="$(printf '%s' "${SUMMARY_JSON}" | /usr/bin/python3 -c 'import json,sys; r=json.load(sys.stdin); print(r["passedTests"], r["failedTests"], r["skippedTests"], r["totalTestCount"])')"
read -r passed failed skipped total <<< "${COUNTS}"
[[ "${passed}" == "6" ]] || qa_die "${SCENARIO_ID}: expected 6 passed tests, got ${passed}"
[[ "${failed}" == "0" ]] || qa_die "${SCENARIO_ID}: expected 0 failed tests, got ${failed}"
[[ "${skipped}" == "0" ]] || qa_die "${SCENARIO_ID}: expected 0 skipped tests, got ${skipped}"
[[ "${total}" == "6" ]] || qa_die "${SCENARIO_ID}: expected total 6, got ${total}"

phase_marker "COMPLETE passed=${passed} failed=${failed} skipped=${skipped}"
qa_pass
