#!/usr/bin/env bash
#
# QA WP-03 — all XCTest targets green (Domain / IPC / App).
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

XCODEPROJ="${NATIVE_DIR}/Torrentino.xcodeproj"
SCHEME="Torrentino"
LOG="$(qa_mktemp)/xcodebuild-test.log"

qa_log "xcodebuild test (Domain + IPC + App)…"
set +e
xcodebuild test \
	-project "${XCODEPROJ}" \
	-scheme "${SCHEME}" \
	-destination 'platform=macOS,arch=arm64' \
	-only-testing:TorrentinoDomainTests \
	-only-testing:TorrentinoIPCTests \
	-only-testing:TorrentinoAppTests \
	CODE_SIGN_IDENTITY="Developer ID Application" \
	DEVELOPMENT_TEAM=438UQRF7JV \
	2>&1 | tee "${LOG}"
test_rc=${PIPESTATUS[0]}
set -e

if [[ ${test_rc} -ne 0 ]]; then
	# Surface XCTest failures for the BUG report.
	grep -E 'error:|failed|XCTAssert|Testing failed|TEST FAILED' "${LOG}" | tail -n 80 >&2 || true
	qa_die "xcodebuild test failed (rc=${test_rc}); see ${LOG}"
fi

# Ensure each target actually ran (not silently skipped).
LOG_TXT="$(cat "${LOG}")"
assert_match "${LOG_TXT}" "TorrentinoDomainTests" "Domain tests executed"
assert_match "${LOG_TXT}" "TorrentinoIPCTests" "IPC tests executed"
assert_match "${LOG_TXT}" "TorrentinoAppTests" "App tests executed"
if [[ "${LOG_TXT}" == *"TEST SUCCEEDED"* ]] || [[ "${LOG_TXT}" == *"Test Succeeded"* ]]; then
	qa_ok "TEST SUCCEEDED banner present"
else
	qa_die "missing TEST SUCCEEDED in xcodebuild output"
fi

qa_ok "all XCTest targets green"
qa_pass
