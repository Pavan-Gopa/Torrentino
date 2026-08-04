#!/usr/bin/env bash
#
# QA WP-10 — durable two-phase removal (XCTest gates).
#
# Verifies via WPSafeFileOperationsTests:
#   * prepareRemoval mints a durable token whose exact manifest is served back
#     through fetchRemovalManifestPage (never re-derived)
#   * record-only removal (deleteFiles=false) carries an empty manifest
#   * commit trashes EVERY manifest item (files first, then empty directories)
#     and removes the record only on full success
#   * partial failure keeps the record, settles the token cancelled, leaves the
#     per-item journal as evidence, and replays the IDENTICAL batch result
#   * total failure trashes nothing and keeps the record + journal
#   * shared-path protection: files covered by another torrent are skipped,
#     never trashed, record still removed
#   * FileSafetyValidator refuses symlinks / missing items / size changes
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
    -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10CommitRemovalTrashesEveryManifestItemAndRemovesRecord \
    -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10CommitRemovalPartialFailureKeepsRecordAndJournalWithIdempotentReplay \
    -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10CommitRemovalTotalFailureKeepsRecordAndJournal \
    -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10SharedPathRemovalSkipsFilesSharedWithAnotherTorrent \
    -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP10SafetyValidatorRefusesSymlinksMissingItemsAndSizeChanges \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "WP-10 durable removal gates FAILED"
fi
qa_ok "durable token + exact manifest + trash commit + partial/total failure + shared paths + safety validator GREEN"

qa_pass
