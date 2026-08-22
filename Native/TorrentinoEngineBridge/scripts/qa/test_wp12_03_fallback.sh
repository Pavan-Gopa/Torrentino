#!/usr/bin/env bash
#
# QA WP-12 - §12.8 fallback coverage.
#
# Verifies the fallback matrix from outside the unit tests:
#   * support-check --inject-fail-device 1 -> unsupported with injected failure
#   * FailureTests + CancellationTests suites (runtime fallback paths) pass
#   * bench --backend metal on a real corpus produces fallbacks=0 rows
#     (no spurious fallback on healthy hardware)
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

SWIFT_BIN="${NATIVE_DIR}/TorrentinoHashing/.build/debug/TorrentinoHashingBench"
[[ -x "${SWIFT_BIN}" ]] || qa_die "TorrentinoHashingBench missing; run test_wp12_01_correctness.sh first"

qa_log "Injected device-creation failure report..."
inj="$(TORRENTINO_METAL_EXPERIMENTAL=1 "${SWIFT_BIN}" support-check --inject-fail-device 1 2>/dev/null)"
assert_contains "${inj}" "supported=false" "injected device failure is reported as unsupported"
assert_contains "${inj}" "device=false" "injected device creation failure propagates into the report"

qa_log "Running FailureTests + CancellationTests..."
( cd "${NATIVE_DIR}/TorrentinoHashing" && swift test --filter FailureTests --filter CancellationTests ) \
	> "${TMPDIR}/wp12_fallback_tests.$$.log" 2>&1 || {
	tail -40 "${TMPDIR}/wp12_fallback_tests.$$.log" >&2
	qa_die "FailureTests/CancellationTests failed"
}
rm -f "${TMPDIR}/wp12_fallback_tests.$$.log"
qa_ok "FailureTests + CancellationTests green (device/compile/commit/buffer/selftest fallback)"

ROOT="$(qa_mktemp)"
mkdir -p "${ROOT}/64m"
HARNESS="${BRIDGE_DIR}/.build/harness-2.0.14-release/torrentino-harness"
[[ -x "${HARNESS}" ]] || qa_die "torrentino-harness missing; build via scripts/build_harness.sh"
"${HARNESS}" gen-corpus --path "${ROOT}/64m/payload.bin" --size 67108864 --seed 7 > /dev/null 2>&1

qa_log "bench --backend metal on 64 MiB (expect fallbacks=0)..."
rows="$(TORRENTINO_METAL_EXPERIMENTAL=1 "${SWIFT_BIN}" bench --dir "${ROOT}/64m" --piece 1024 \
	--format hybrid --backend metal --reps 3 2>/dev/null | grep -v '^corpus:' | sed '/^$/d' | tail -n +2 || true)"
row_count="$(printf '%s\n' "${rows}" | sed '/^$/d' | wc -l | tr -d ' ')"
assert_eq "${row_count}" "3" "3 metal bench rows emitted"
printf '%s\n' "${rows}" | while IFS=',' read -r run cell backend wall cpu rss tb ta limit gpu fb staged thr; do
	if [[ "${fb}" != "0" ]]; then
		qa_die "metal row ${run} reported fallbacks=${fb}, expected 0"
	fi
	if [[ "${backend}" != "metal" ]]; then
		qa_die "row ${run} backend=${backend}, expected metal"
	fi
done
qa_ok "no spurious Metal fallback on healthy hardware"

qa_pass
