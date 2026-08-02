#!/usr/bin/env bash
#
# QA WP-03 — native empty state is wired (UI + catalog + build/test gate).
#
# Smoke is allowed only as wall-clock gate; substantive checks are static + AppTests.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

CONTENT="${NATIVE_DIR}/TorrentinoApp/Features/ContentView.swift"
XCSTRINGS="${NATIVE_DIR}/TorrentinoApp/Resources/Localizable.xcstrings"
XCODEPROJ="${NATIVE_DIR}/Torrentino.xcodeproj"
LOG="$(qa_mktemp)/empty-state.log"

assert_file "${CONTENT}" "ContentView.swift"
assert_file "${XCSTRINGS}" "Localizable.xcstrings"

CV="$(cat "${CONTENT}")"
assert_contains "${CV}" "emptyState" "emptyState view present"
assert_contains "${CV}" 'String(localized: "empty.no_torrents")' "empty.no_torrents key"
assert_contains "${CV}" 'String(localized: "empty.subtitle")' "empty.subtitle key"
assert_contains "${CV}" "square.stack.3d.up.slash" "empty-state SF Symbol"
# Must not invent torrents in the empty view.
assert_not_contains "${CV}" "TorrentInfo(" "empty state must not fabricate TorrentInfo"

# Catalog keys exist (full EN/RU checked by test_wp03_string_catalog.sh).
assert_contains "$(cat "${XCSTRINGS}")" '"empty.no_torrents"' "catalog has empty.no_torrents"
assert_contains "$(cat "${XCSTRINGS}")" '"empty.subtitle"' "catalog has empty.subtitle"

qa_log "build + AppTests (empty-state linkage)…"
set +e
xcodebuild test \
	-project "${XCODEPROJ}" \
	-scheme Torrentino \
	-destination 'platform=macOS,arch=arm64' \
	-only-testing:TorrentinoAppTests \
	CODE_SIGN_IDENTITY="Developer ID Application" \
	DEVELOPMENT_TEAM=438UQRF7JV \
	2>&1 | tee "${LOG}"
rc=${PIPESTATUS[0]}
set -e
[[ ${rc} -eq 0 ]] || {
	grep -E 'error:|failed|XCTAssert|TEST FAILED' "${LOG}" | tail -n 40 >&2 || true
	qa_die "TorrentinoAppTests failed (rc=${rc})"
}

qa_ok "empty state wired + AppTests green"
qa_pass
