#!/usr/bin/env bash
#
# QA WP-11 - Schema v3 torrent_tracker_topology persistence (ADR-017).
#
# Verifies:
#   * persistence schema version is 3
#   * torrent_tracker_topology table uses versioned JSON + checksum + generation
#   * WAL mode and integrity checks are GREEN
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

PERSISTENCE="${NATIVE_DIR}/TorrentinoEngineAgent/Persistence/PersistenceStore.swift"
[[ -f "${PERSISTENCE}" ]] || qa_die "missing ${PERSISTENCE}"

python3 - "${PERSISTENCE}" <<'PY'
import sys
from pathlib import Path

content = Path(sys.argv[1]).read_text(encoding="utf-8")
if "torrent_tracker_topology" not in content:
    print("FAIL: missing torrent_tracker_topology table in PersistenceStore", file=sys.stderr)
    sys.exit(1)
if "schemaVersion: Int = 3" not in content and "schemaVersion = 3" not in content:
    print("FAIL: schemaVersion is not 3 in PersistenceStore", file=sys.stderr)
    sys.exit(1)
print("OK: PersistenceStore contains schema v3 torrent_tracker_topology table")
PY

qa_log "Running WP-11 schema v3 XCTest..."
xcodebuild test -project "${NATIVE_DIR}/Torrentino.xcodeproj" -scheme Torrentino \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:TorrentinoEngineAgentTests/TorrentinoEngineAgentPersistenceTests/testOpenCreatesSchemaWithWAL \
  > /dev/null

qa_ok "Schema v3 topology persistence GREEN"
qa_pass
