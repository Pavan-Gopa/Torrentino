#!/usr/bin/env bash
#
# QA WP-01 — verify_no_homebrew.sh positive path (feature 7).
#
# Verifies that the shipped-style harness binaries pass the runtime dependency
# gate: arm64-only, macOS 13.0+, and no /opt/homebrew or /usr/local runtime
# links or rpaths. Checked for both the default and fallback libtorrent builds.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"
source "${LOCK_FILE}"

check_binary() { # <binary> <label>
	local bin="$1" label="$2" out
	[[ -x "${bin}" ]] || qa_die "${label}: binary missing: ${bin}"
	set +e
	out="$(bash "${VERIFY_NO_HOMEBREW_SH}" "${bin}" 2>&1)"
	local st=$?
	set -e
	assert_eq "${st}" "0" "${label}: verify_no_homebrew exit code"
	assert_contains "${out}" "OK: arm64" "${label}: clean banner"
	assert_not_contains "${out}" "error:" "${label}: no gate errors"
	# Independent double-check of the actual load commands.
	assert_not_contains "$(otool -L "${bin}")" "/opt/homebrew" "${label}: no Homebrew dylib link"
	assert_not_contains "$(otool -L "${bin}")" "/usr/local" "${label}: no /usr/local dylib link"
}

check_binary "${BRIDGE_DIR}/.build/harness-${LT_DEFAULT_VERSION}-release/torrentino-harness" "default ${LT_DEFAULT_VERSION}"
check_binary "${BRIDGE_DIR}/.build/harness-2.0.13-release/torrentino-harness" "fallback 2.0.13"

qa_pass
