#!/usr/bin/env bash
# WP-14 Release XCTest measurement driver. Isolated test-profile state only.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

MEAS_DIR="${REPO_ROOT}/Measurements/wp14"
mkdir -p "${MEAS_DIR}"
RUN_ID="${WP14_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
LOG="${MEAS_DIR}/xctest-${RUN_ID}.log"
RESULT="${MEAS_DIR}/xctest-${RUN_ID}.xcresult"
DERIVED="${REPO_ROOT}/build/WP14DerivedData"
rm -rf "${RESULT}"

qa_log "WP-14 in-process Release measurements run_id=${RUN_ID}"
set +e
WP14_MEASUREMENTS_DIR="${MEAS_DIR}" WP14_RUN_ID="${RUN_ID}" \
xcodebuild test \
    -project "${NATIVE_DIR}/Torrentino.xcodeproj" \
    -scheme Torrentino \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "${DERIVED}" \
    -resultBundlePath "${RESULT}" \
    -only-testing:TorrentinoAppTests/WP14ProjectionMeasurements/testFiveHundredRowProjectionP50P95 \
    -only-testing:TorrentinoEngineAgentTests/WP14PerformanceMeasurements/testWP14InProcessPerformanceCampaign \
    ENABLE_TESTABILITY=YES \
    2>&1 | tee "${LOG}"
status=${PIPESTATUS[0]}
set -e

assert_file "${LOG}" "WP-14 XCTest transcript"
assert_file "${RESULT}/Info.plist" "WP-14 xcresult bundle"
projection_artifact="${MEAS_DIR}/projection-${RUN_ID}.csv"
inprocess_artifact="${MEAS_DIR}/inprocess-${RUN_ID}.csv"
[[ -f "${projection_artifact}" ]] || projection_artifact="${MEAS_DIR}/projection-latest.csv"
[[ -f "${inprocess_artifact}" ]] || inprocess_artifact="${MEAS_DIR}/inprocess-latest.csv"
assert_file "${projection_artifact}" "projection measurement artifact"
assert_file "${inprocess_artifact}" "in-process measurement artifact"
if [[ "${status}" -ne 0 ]]; then
    qa_die "WP-14 measurement XCTest reported a product/SLO failure; evidence preserved in ${LOG}"
fi
qa_ok "WP-14 in-process metrics: ${inprocess_artifact}"
qa_pass
