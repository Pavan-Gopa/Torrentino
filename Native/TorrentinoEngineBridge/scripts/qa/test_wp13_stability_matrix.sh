#!/usr/bin/env bash
#
# WP-13 ADR-020 deterministic stabilization matrix.
# Runs only XCTest/TestProfile contracts. It never launches the product agent,
# reads Application Support, or reaches the external BitTorrent network.
#
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

SCENARIO_ID="WP13-STABILITY-MATRIX-001"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"
DERIVED_DATA="${REPO_ROOT}/build/WP13StabilityMatrixDerivedData"
WORK_DIR="$(qa_mktemp)"
RESULT_BUNDLE="${WORK_DIR}/WP13StabilityMatrix.xcresult"
BUILD_LOG="${WORK_DIR}/build.log"
TEST_LOG="${WORK_DIR}/test.log"
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

phase_marker "EXECUTE thirty deterministic matrix contracts"
set +e
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "${DERIVED_DATA}" \
    -resultBundlePath "${RESULT_BUNDLE}" \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testCommitAddImmediateStartRunningNotIdle \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testMultiFileRunningDesiredStateAndOfflineRecovery \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testRestoreWarningClearsAfterHealthyEngineAdmission \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testStatusCacheMergesSentinelsAndClearsTransientHealth \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testRedactedLogSinkRotatesAndWritesDisposableEvidence \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testFileSelectionPrioritiesRoundTrip \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testTransferRatesAndProgressProjection \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testDeltaContinuityTwoAddsSingleBatch \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testSnapshotRequiredFlushesImmediately \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testEventBusCoalescesBurstIntoOneDelivery \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testConcurrentMixedCommandsAllResolve \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testRestoreToleratesExtraFieldsAndOldShape \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testWP13StabilityR0DegradesAndFailsSnapshotClosed \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testWP13StabilityDiagnosticsRedactsSecretsAndPreservesSafeCorrelation \
    -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testOpenCreatesSchemaWithWAL \
    -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testRepeatedKillNineRestore \
    -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testNoDuplicateOrLostRecordsWithGenerations \
    -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testRecordOnlyInWALRestoredAfterCrash \
    -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testCorruptDatabaseControlledRecovery \
    -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10KeepDataRemovalLeavesPayloadByteIdentical \
    -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10CommitRemovalTrashesEveryManifestItemAndRemovesRecord \
    -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10CommitRemovalPartialFailureKeepsRecordAndJournalWithResumableReplay \
    -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10MoveRecoveryResumesInterruptedMove \
    -only-testing:TorrentinoAppTests/TorrentinoAppTests/testTorrentListProjectionSearchFilterAndSort \
    -only-testing:TorrentinoAppTests/TorrentinoAppTests/testTorrentListRowProjectionComputesActiveDownloadETA \
    -only-testing:TorrentinoAppTests/TorrentinoAppTests/testTorrentListRowProjectionGatesETAOnAuthoritativeHealthAndActivity \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testSnapshotRevisionMonotonic \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testDroppedDeltaRequiresFullSnapshot \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testEnvelopeConcurrentEncodeDecodeStress \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testReconnectPolicyBackoffMonotonic \
    2>&1 | tee "${TEST_LOG}"
test_rc=${PIPESTATUS[0]}
set -e
[[ ${test_rc} -eq 0 ]] || exit "${test_rc}"

phase_marker "VERIFY exact result count and zero failures"
SUMMARY_JSON="$(xcrun xcresulttool get test-results summary --path "${RESULT_BUNDLE}" --format json)"
COUNTS="$(printf '%s' "${SUMMARY_JSON}" | /usr/bin/python3 -c 'import json,sys; r=json.load(sys.stdin); print(r["passedTests"], r["failedTests"], r["skippedTests"], r["totalTestCount"])')"
read -r passed failed skipped total <<< "${COUNTS}"
[[ "${passed}" == "30" ]] || qa_die "${SCENARIO_ID}: expected 30 passed tests, got ${passed}"
[[ "${failed}" == "0" ]] || qa_die "${SCENARIO_ID}: expected 0 failed tests, got ${failed}"
[[ "${skipped}" == "0" ]] || qa_die "${SCENARIO_ID}: expected 0 skipped tests, got ${skipped}"
[[ "${total}" == "30" ]] || qa_die "${SCENARIO_ID}: expected total 30, got ${total}"

phase_marker "COMPLETE passed=${passed} failed=${failed} skipped=${skipped}"
qa_pass
