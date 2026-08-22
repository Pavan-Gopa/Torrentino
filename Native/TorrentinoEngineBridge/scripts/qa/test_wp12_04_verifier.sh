#!/usr/bin/env bash
#
# QA WP-12 - independent BEP-52 validator battery (§12.7 "independent validator").
#
# Cross-checks Swift-written torrents against libtorrent 2.0.14:
#   * v1 piece lists bit-identical (single-file corpora)
#   * v2 file-tree pieces roots byte-equal to libtorrent generate_buf()
#   * piece-layer presence, length AND content byte-equal
#   * structure parse passes on both sides
#   * bench-hash emits the shared CSV schema with valid thermal evidence
#
# Corpus: tiny (32 KiB, sub-piece file) and 64m (64 MiB) x piece 256/1024/4096 KiB
# x format v1/v2/hybrid = 18 cells.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

SWIFT_BIN="${NATIVE_DIR}/TorrentinoHashing/.build/debug/TorrentinoHashingBench"
HARNESS="${BRIDGE_DIR}/.build/harness-2.0.14-release/torrentino-harness"
[[ -x "${SWIFT_BIN}" ]] || qa_die "TorrentinoHashingBench missing; run test_wp12_01_correctness.sh first"
[[ -x "${HARNESS}" ]] || qa_die "torrentino-harness missing; build via scripts/build_harness.sh"

ROOT="$(qa_mktemp)"
mkdir -p "${ROOT}/tiny" "${ROOT}/64m"
"${HARNESS}" gen-corpus --path "${ROOT}/tiny/payload.bin" --size 32768 --seed 5 > /dev/null 2>&1
"${HARNESS}" gen-corpus --path "${ROOT}/64m/payload.bin" --size 67108864 --seed 7 > /dev/null 2>&1

cells=0
for corpus in tiny 64m; do
	for piece in 256 1024 4096; do
		for fmt in v1 v2 hybrid; do
			torrent="${ROOT}/${corpus}-${fmt}-${piece}.torrent"
			"${SWIFT_BIN}" torrent --dir "${ROOT}/${corpus}" --piece "${piece}" --format "${fmt}" \
				--out "${torrent}" > /dev/null 2>&1 || qa_die "swift torrent failed: ${corpus} ${fmt} ${piece}"
			verdict="$("${HARNESS}" verify-torrent --torrent "${torrent}" --dir "${ROOT}" --name "${corpus}" 2>&1)"
			assert_contains "${verdict}" "verify-torrent: PASS" "verify ${corpus} ${fmt} piece=${piece}KiB"
			cells=$((cells + 1))
		done
	done
done
qa_ok "independent verifier battery: ${cells}/18 cells PASS"

qa_log "bench-hash CSV shape + thermal evidence..."
rows="$("${HARNESS}" bench-hash --dir "${ROOT}" --name 64m --piece 1024 --format hybrid --reps 3 2>/dev/null | grep -v ' INFO ' || true)"
header="$(printf '%s\n' "${rows}" | head -1)"
assert_eq "${header}" \
	"run,cell,backend,wall_s,cpu_s,peak_rss_mb,thermal_before,thermal_after,cpu_speed_limit,gpu_wall_s,fallbacks,staged_bytes,throughput_mib_s" \
	"bench-hash CSV header matches the shared schema"
count="$(printf '%s\n' "${rows}" | sed '/^$/d' | tail -n +2 | wc -l | tr -d ' ')"
assert_eq "${count}" "3" "bench-hash emits 3 libtorrent rows"
printf '%s\n' "${rows}" | tail -n +2 | while IFS=',' read -r run cell backend wall cpu rss tb ta limit gpu fb staged thr; do
	[[ "${backend}" == "libtorrent" ]] || qa_die "bench-hash row backend=${backend}"
	[[ "${cell}" == "64m/1024KiB" ]] || qa_die "bench-hash row cell=${cell}"
	[[ "${tb}" == "100" && "${ta}" == "100" ]] || qa_die "thermal evidence columns not '100' (row ${run}: ${tb}/${ta})"
done
qa_ok "bench-hash CSV rows well-formed with thermal evidence (no CPU power status recorded)"

qa_pass
