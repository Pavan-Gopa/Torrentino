#!/usr/bin/env bash
#
# Torrentino WP-09 fault matrix gate.
# Role: execute production-path XCTest cases for pressure gates, bounds,
#       storage faults, volume identity, crash-loop recovery and path identity.
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
   -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testWP09OfflinePreservesDesiredStateAndRecoversWithoutSpin \
   -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testWP09PressureGateBlocksHeavyWorkUntilRecovery \
   -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testWP09TypedEngineFailureIsNotCollapsedToBusy \
   -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testWP09ReaddUsesPerRecordBackoff \
   -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testWP09PendingInspectionBytesAreBounded \
   -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testWP09DuplicateCommitUsesBoundedIdempotencyPath \
   -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testWP09VolumeIdentityAndUnknownFreeSpaceAreConservative \
   -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testWP09PersistenceVolumeFaultCrossesCommitBoundary \
   -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testWP09CrashLoopSafeModeRestartClearsAndReconciles \
   -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testWP09MonitorGenerationIncludesRouteIdentity \
   -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testWP09CrashLoopGuardCanBeExplicitlyCleared \
   -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testWP09BridgeStatusCacheEnforcesByteBudget

echo "WP-09 fault matrix: PASS"
