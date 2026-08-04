#!/usr/bin/env bash
#
# QA WP-10 — durable two-phase removal (XCTest gates).
#
# Verifies via WPSafeFileOperationsTests:
#   * prepareRemoval mints a durable token whose exact manifest is served back
#     through fetchRemovalManifestPage (never re-derived)
#   * record-only removal (deleteFiles=false) carries an empty manifest
#   * keep-data commit removes only the record and preserves payload bytes
#   * commit trashes EVERY manifest item (files first, then empty directories)
#     and removes the record only on full success
#   * partial failure keeps the record + journal, keeps the token PENDING, and
#     a resumed replay returns the IDENTICAL batch result without re-trashing
#   * total failure trashes nothing and keeps the record + journal
#   * shared-path protection: files covered by another torrent are skipped,
#     never trashed; dirs holding shared data refuse (not_empty)
#   * FileSafetyValidator refuses symlinks / missing items / size changes
#   * Gate 1: an unmanifested sibling inside a manifest dir survives
#   * Gate 7: ancestor symlink swap / same-size replacement / hardlink swap are
#     refused before any mutation (identity_changed / unsafe_symlink)
#   * Gate 8: journal append/update failures abort fail-closed; a settle
#     failure keeps the record and the pending token is restored + enumerable
#     after a restart (fetchPendingRemovals), then resumes to completion
#   * pending removal restore is read-only until an explicit retry
#   * a settled outcome repairs a leftover record after a restart
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running WP-10 durable removal gates..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
     -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10PrepareRemovalCreatesDurableTokenAndExactManifestPage \
     -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10PrepareRemovalWithoutDeleteFilesKeepsEmptyManifest \
     -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10KeepDataRemovalLeavesPayloadByteIdentical \
     -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10CommitRemovalTrashesEveryManifestItemAndRemovesRecord \
    -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10CommitRemovalPartialFailureKeepsRecordAndJournalWithResumableReplay \
    -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10CommitRemovalTotalFailureKeepsRecordAndJournal \
    -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10SharedPathRemovalSkipsFilesSharedWithAnotherTorrent \
    -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10SafetyValidatorRefusesSymlinksMissingItemsAndSizeChanges \
    -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10PrepareRemovalPersistenceCountFailureFailsClosed \
    -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10FetchPendingRemovalsPersistenceFailureDoesNotFabricateProgress \
    -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10UnmanifestedSiblingSurvivesDirectoryTrash \
    -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10AncestorSymlinkSwapRefusedBeforeAnyMutation \
    -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10SameSizeReplacementRefusedByIdentity \
    -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10HardlinkSwapRefusedByIdentity \
     -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10JournalAppendFailureAbortsBatchBeforeAnyMutation \
     -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10JournalUpdateFailureAbortsFailClosedAndResumes \
     -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10SettleFailureFailsClosedAndPendingTokenSurvivesRestart \
     -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10PendingRemovalRestoreDoesNotAutoResume \
     -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10CommittedOutcomeReplayRepairsRecordAfterSettlementCrash \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "WP-10 durable removal gates FAILED"
fi
qa_ok "durable token + exact manifest + trash commit + partial/total failure + shared paths + safety validator + adversarial gates GREEN"

qa_pass
