#!/usr/bin/env bash
#
# Torrentino WP-09 fault matrix gate.
# Role: execute the native XCTest cases for bounded resources, storage faults,
#       missing-volume behavior, event overflow and offline recovery.
# Must-not: touch Legacy or claim a fault is recovered without running the
#           coordinator/IPC tests.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "${ROOT_DIR}"

xcodebuild test \
  -project Native/Torrentino.xcodeproj \
  -scheme Torrentino \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testWP09ResourceBudgetIsBoundedAndShrinksUnderPressure \
  -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testWP09TypedStorageFaultsCarryVolumeAndRoundTrip \
  -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testWP09IdempotencyTrackerEvictsOldestEntry \
  -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testWP09StorageProbeNeverCreatesMissingVolumePath \
  -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testWP09EventBusOverflowRequestsSnapshotAndStaysBounded \
  -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testWP09OfflinePreservesDesiredStateAndRecoversWithoutSpin

echo "WP-09 fault matrix: PASS"
