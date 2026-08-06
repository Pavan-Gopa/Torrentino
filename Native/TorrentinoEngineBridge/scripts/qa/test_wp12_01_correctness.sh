#!/usr/bin/env bash
#
# QA WP-12 - Metal research backend correctness gate (§12.7).
#
# Verifies:
#   * full Swift test suite (20 tests) passes:
#       KnownAnswerTests  - bit-for-bit published vectors (SHA-256/SHA-1)
#       CorrectnessTests  - v1/v2/hybrid vs CPU reference + 100 randomized
#                           single-file + 100 randomized two-file cases
#       StressTests       - 1000 iterations, zero mismatches
#       FailureTests      - all §12.8 fallback paths (device/compile/commit/
#                           buffer/selftest), support report both ways
#       CancellationTests - cancellation latency bounds
#   * support-check reports Metal unsupported without the experimental flag
#     and supported with it (gated environment only).
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

SWIFT_BIN="${NATIVE_DIR}/TorrentinoHashing/.build/debug/TorrentinoHashingBench"
if [[ ! -x "${SWIFT_BIN}" ]]; then
	qa_log "TorrentinoHashingBench not built; building..."
	swift build --package-path "${NATIVE_DIR}/TorrentinoHashing" --configuration debug > /dev/null
fi

qa_log "Running full Swift test suite (20 tests, ~80s)..."
( cd "${NATIVE_DIR}/TorrentinoHashing" && swift test ) > "${TMPDIR}/wp12_swift_test.$$.log" 2>&1 || {
	tail -40 "${TMPDIR}/wp12_swift_test.$$.log" >&2
	qa_die "swift test failed"
}
rm -f "${TMPDIR}/wp12_swift_test.$$.log"
qa_ok "swift test: 20/20 green (known answers, correctness, stress, failure, cancellation)"

qa_log "Support report without experimental flag..."
unset TORRENTINO_METAL_EXPERIMENTAL
without_flag="$("${SWIFT_BIN}" support-check 2>/dev/null)"
assert_contains "${without_flag}" "supported=false" "Metal unsupported without TORRENTINO_METAL_EXPERIMENTAL"
assert_contains "${without_flag}" "flag" "reason names the experimental flag"

qa_log "Support report with experimental flag..."
with_flag="$(TORRENTINO_METAL_EXPERIMENTAL=1 "${SWIFT_BIN}" support-check 2>/dev/null)"
assert_contains "${with_flag}" "supported=true device=true library=true selftest=true lpm=false" \
	"Metal fully supported under flag (no LPM, no thermal gate)"
assert_contains "${with_flag}" "reason=nil" "no rejection reason when supported"

qa_pass
