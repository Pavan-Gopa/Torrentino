#!/usr/bin/env bash
#
# QA WP-06 — Schema migration (feature 2).
#
# Verifies via TorrentinoEngineAgentPersistenceTests:
#   * a fresh database gets the v1 schema (schema_version table, MAX(version)=1)
#   * all six v1 tables exist and are usable (75-record fixture round-trip:
#     torrents, resume_data, metainfo, session_state, operation_journal,
#     quarantine counts all correct)
#   * reopening an existing v1 database is idempotent — migrations do not
#     re-run and never conflict (second open: integrityOK, not rebuilt)
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running persistence schema migration tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testOpenCreatesSchemaWithWAL \
    -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testFixtureSeventyFiveRecords \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Schema migration tests FAILED"
fi
qa_ok "Fresh DB schema v1 + idempotent reopen + 75-record fixture GREEN"

qa_pass
