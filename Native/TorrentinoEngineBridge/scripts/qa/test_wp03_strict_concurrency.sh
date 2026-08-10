#!/usr/bin/env bash
#
# QA WP-03 — Strict concurrency complete + clean build (0 warnings).
#
# Verifies Shared.xcconfig freezes SWIFT_STRICT_CONCURRENCY=complete and that
# `xcodebuild build` of the Torrentino scheme completes with zero warnings
# (warnings-as-errors is also required in Shared.xcconfig).
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

XCODEPROJ="${NATIVE_DIR}/Torrentino.xcodeproj"
SCHEME="Torrentino"
SHARED_XCCONFIG="${NATIVE_DIR}/Config/Shared.xcconfig"
LOG="$(qa_mktemp)/xcodebuild-build.log"

assert_file "${XCODEPROJ}/project.pbxproj" "Xcode project present"
assert_file "${SHARED_XCCONFIG}" "Shared.xcconfig present"

CFG="$(cat "${SHARED_XCCONFIG}")"
assert_contains "${CFG}" "SWIFT_STRICT_CONCURRENCY = complete" "strict concurrency = complete"
assert_contains "${CFG}" "SWIFT_TREAT_WARNINGS_AS_ERRORS = YES" "warnings as errors"
assert_contains "${CFG}" "SWIFT_VERSION = 6.0" "Swift 6"

qa_log "xcodebuild build (scheme=${SCHEME}, arm64)…"
set +e
xcodebuild build \
	-project "${XCODEPROJ}" \
	-scheme "${SCHEME}" \
	-destination 'platform=macOS,arch=arm64' \
	CODE_SIGN_IDENTITY="Developer ID Application" \
	DEVELOPMENT_TEAM=438UQRF7JV \
	2>&1 | tee "${LOG}"
build_rc=${PIPESTATUS[0]}
set -e

[[ ${build_rc} -eq 0 ]] || qa_die "xcodebuild build failed (rc=${build_rc}); see ${LOG}"

# Treat compiler/linker warning lines as failures even if TREAT_WARNINGS_AS_ERRORS
# were accidentally relaxed on a target. Xcode 26 emits this tool-owned warning
# for applications that intentionally do not link AppIntents; it is unrelated
# to source concurrency and is the only accepted exclusion.
warn_lines="$(grep -E 'warning:|WARNING:' "${LOG}" \
	| grep -vE 'note:|ignoring|appintentsmetadataprocessor.*warning: Metadata extraction skipped\\. No AppIntents\\.framework dependency found\\.' \
	|| true)"
if [[ -n "${warn_lines}" ]]; then
	printf '%s\n' "${warn_lines}" >&2
	qa_die "build produced compiler/linker warning lines (strict concurrency gate)"
fi
qa_ok "build exit 0 with zero compiler/linker warning lines"

qa_pass
