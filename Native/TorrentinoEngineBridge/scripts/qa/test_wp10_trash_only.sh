#!/usr/bin/env bash
#
# QA WP-10 — Trash-only removal primitive (real platform Trash, temp volume).
#
# Verifies with the REAL FileManager trashItem (no test stubs):
#   * the file disappears from the origin directory
#   * the platform reports a Trash destination for it (never a permanent
#     delete) and the file exists there afterwards
#   * an untouched control payload in the same workspace keeps byte-identical
#     content (keep-data unchanged payload)
#   * Gate 1: a sibling file that is NOT the trash target stays in place — the
#     primitive never takes unmanifested content with it
#
# Safety: everything lives under qa_mktemp; the probe's own Trash item is
# removed again before exit (the QA script trashes nothing of the user's).
# No production path is ever touched.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

WORK="$(qa_mktemp)"
ORIGIN="${WORK}/origin"
TRASH_NAME="wp10-trash-probe.bin"
mkdir -p "${ORIGIN}"

printf 'wp10 trash probe payload' > "${ORIGIN}/${TRASH_NAME}"
printf 'wp10 untouched control payload' > "${ORIGIN}/control.bin"
CONTROL_SHA="$(shasum -a 256 "${ORIGIN}/control.bin" | awk '{print $1}')"

SWIFT_PROBE="${WORK}/trash_probe.swift"
cat > "${SWIFT_PROBE}" <<'EOF'
import Foundation
let fm = FileManager.default
let url = URL(fileURLWithPath: CommandLine.arguments[1])
var resulting: NSURL?
try fm.trashItem(at: url, resultingItemURL: &resulting)
if let resulting {
    print(resulting.path ?? "")
}
EOF

qa_log "Trashing ${TRASH_NAME} via FileManager.trashItem (real platform Trash)..."
TRASH_DEST="$(swift "${SWIFT_PROBE}" "${ORIGIN}/${TRASH_NAME}")"
assert_ne "${TRASH_DEST:-}" "" "trashItem must report a Trash destination"
assert_ne "${TRASH_DEST}" "${ORIGIN}/${TRASH_NAME}" "destination must differ from the origin path"
assert_file "${TRASH_DEST}" "file must exist at the reported Trash destination"
assert_ne "$(test -e "${ORIGIN}/${TRASH_NAME}" && echo present || echo gone)" "present" \
    "origin file must be gone after trashItem"

CONTROL_SHA_AFTER="$(shasum -a 256 "${ORIGIN}/control.bin" | awk '{print $1}')"
assert_eq "${CONTROL_SHA_AFTER}" "${CONTROL_SHA}" \
    "untouched payload must keep byte-identical content"
assert_file "${ORIGIN}/control.bin" \
    "unmanifested sibling must survive the trash of another item"

# Clean up the probe's own Trash item (test artifact, not user data).
rm -f "${TRASH_DEST}"
qa_ok "Trash-only removal: origin gone, Trash holds the file, control payload + sibling unchanged"
qa_pass
