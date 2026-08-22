#!/usr/bin/env bash
#
# QA WP-12 - benchmark matrix driver (§12.4/§12.7).
#
# Runs the CPU (Swift), Metal (Swift) and libtorrent (C++) backends over the
# corpus x piece-size matrix, 10 reps per cell, randomized backend order per
# rep (Swift bench) and rotated backend order across cells (libtorrent block),
# with a warm-up pass per cell before the timed reps. No system purge is
# performed (page cache is left untouched between runs, §12.7).
#
# Output: CSV rows (shared schema) appended to Measurements/wp12/ in the repo,
# plus an environment snapshot. The CSV is the input for analyze_wp12.py which
# computes medians / 95% CI and the §12.7 gate verdict.
#
# Usage:
#   bash test_wp12_02_benchmarks.sh          # reduced smoke matrix (3 reps)
#   FULL=1 bash test_wp12_02_benchmarks.sh   # full matrix (10 reps, §12.7)
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

SWIFT_BIN="${NATIVE_DIR}/TorrentinoHashing/.build/debug/TorrentinoHashingBench"
HARNESS="${BRIDGE_DIR}/.build/harness-2.0.14-release/torrentino-harness"
[[ -x "${SWIFT_BIN}" ]] || qa_die "TorrentinoHashingBench missing; run test_wp12_01_correctness.sh first"
[[ -x "${HARNESS}" ]] || qa_die "torrentino-harness missing; build via scripts/build_harness.sh"

if [[ "${FULL:-0}" == "1" ]]; then
	REPS=10
	cells=( "64m 256" "64m 1024" "64m 4096" "64m 16384" "1g 1024" "1g 4096" "1g 16384" )
else
	REPS=3
	cells=( "64m 1024" "1g 1024" )
fi

ROOT="$(qa_mktemp)"
mkdir -p "${ROOT}/64m" "${ROOT}/1g"
"${HARNESS}" gen-corpus --path "${ROOT}/64m/payload.bin" --size 67108864 --seed 7 > /dev/null 2>&1
"${HARNESS}" gen-corpus --path "${ROOT}/1g/payload.bin" --size 1073741824 --seed 7 > /dev/null 2>&1

# 4 GiB corpus for the §12.7 eligibility line (>=4 GiB): needs ~4.3 GiB free.
free_kb="$(df -k /System/Volumes/Data | tail -1 | awk '{print $4}')"
if [[ "${free_kb}" -gt 4600000 ]]; then
	mkdir -p "${ROOT}/4g"
	if "${HARNESS}" gen-corpus --path "${ROOT}/4g/payload.bin" --size 4294967296 --seed 7 > /dev/null 2>&1; then
		if [[ "${FULL:-0}" == "1" ]]; then
			cells+=( "4g 1024" "4g 4096" "4g 16384" )
		fi
	else
		qa_log "4g corpus generation failed; 4g cells dropped (disk constraint)"
	fi
else
	qa_log "4g corpus skipped: only ${free_kb} KiB free"
fi

MEAS_DIR="${REPO_ROOT}/Measurements/wp12"
mkdir -p "${MEAS_DIR}"
ts="$(date +%Y%m%d-%H%M%S)"
csv="${MEAS_DIR}/bench-${ts}.csv"
envlog="${MEAS_DIR}/env-${ts}.txt"

# Environment snapshot (evidence for the report).
{
	echo "== WP-12 benchmark environment snapshot: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "host: $(hostname)  user: ${USER}"
	echo "macos: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
	echo "arch: $(uname -m)  kernel: $(uname -r)"
	echo "chip: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo n/a)"
	echo "hw.ncpu: $(sysctl -n hw.ncpu)  hw.memsize: $(($(sysctl -n hw.memsize) / 1024 / 1024 / 1024)) GiB"
	echo "lowpowermode: $(pmset -g | awk '/lowpowermode/{print $2}')"
	echo "disk_free_bytes: $(df -k /System/Volumes/Data | tail -1 | awk '{print $4}')"
	echo "swift_bench_bin: ${SWIFT_BIN}"
	echo "harness_bin: ${HARNESS} (libtorrent 2.0.14)"
	echo "reps: ${REPS}   full_matrix: ${FULL:-0}"
} | tee "${envlog}" >&2

echo "csv: ${csv}" >&2
{
	echo "run,cell,backend,wall_s,cpu_s,peak_rss_mb,thermal_before,thermal_after,cpu_speed_limit,gpu_wall_s,fallbacks,staged_bytes,throughput_mib_s"
} > "${csv}"

# Randomize cell order (no shuf on macOS; RANDOM is fine for ORDER only —
# timings themselves are the measured quantity). Lines are read whole to
# preserve the "corpus piece" pairing (bash 3.2 word-splits $() output).
orderfile="$(qa_mktemp)/cells.order"
for cell in "${cells[@]}"; do
	printf '%s\n' "$RANDOM|${cell}" >> "${orderfile}"
done
sort -t'|' -k1 -n "${orderfile}" -o "${orderfile}"
order=()
while IFS= read -r item; do
	order+=("${item#*|}")
done < "${orderfile}"
cell_idx=0
for cell in "${order[@]}"; do
	read -r corpus piece <<< "${cell}"
	qa_log "cell: corpus=${corpus} piece=${piece}KiB"
	corpus_dir="${ROOT}/${corpus}"

	# Backend rotation across cells: 0=cpu,1=libtorrent,2=metal,3=metal,4=cpu,5=libtorrent ...
	case $((cell_idx % 3)) in
		0) first="cpu"; second="libtorrent"; third="metal" ;;
		1) first="libtorrent"; second="metal"; third="cpu" ;;
		2) first="metal"; second="cpu"; third="libtorrent" ;;
	esac

	# Warm-up pass: one rep per backend (cold page cache for this cell).
	TORRENTINO_METAL_EXPERIMENTAL=1 "${SWIFT_BIN}" bench --dir "${corpus_dir}" --piece "${piece}" \
		--format hybrid --backend all --reps 1 > /dev/null 2>&1 || qa_die "swift warmup failed ${corpus} ${piece}"
	"${HARNESS}" bench-hash --dir "${ROOT}" --name "${corpus}" --piece "${piece}" \
		--format hybrid --reps 1 > /dev/null 2>&1 || qa_die "harness warmup failed ${corpus} ${piece}"

	for backend in "${first}" "${second}" "${third}"; do
		case "${backend}" in
			cpu)
				TORRENTINO_METAL_EXPERIMENTAL=1 "${SWIFT_BIN}" bench --dir "${corpus_dir}" \
					--piece "${piece}" --format hybrid --backend cpu --reps "${REPS}" \
					2>> "${MEAS_DIR}/bench-err-${ts}.log" | grep -v '^corpus:' | grep -v '^run,cell,' >> "${csv}" \
					|| qa_die "swift cpu bench failed ${corpus} ${piece}"
				;;
			metal)
				TORRENTINO_METAL_EXPERIMENTAL=1 "${SWIFT_BIN}" bench --dir "${corpus_dir}" \
					--piece "${piece}" --format hybrid --backend metal --reps "${REPS}" \
					2>> "${MEAS_DIR}/bench-err-${ts}.log" | grep -v '^corpus:' | grep -v '^run,cell,' >> "${csv}" \
					|| qa_die "swift metal bench failed ${corpus} ${piece}"
				;;
			libtorrent)
				"${HARNESS}" bench-hash --dir "${ROOT}" --name "${corpus}" --piece "${piece}" \
					--format hybrid --reps "${REPS}" \
					2>> "${MEAS_DIR}/bench-err-${ts}.log" | grep -v ' INFO ' | sed '/^$/d' | tail -n +2 >> "${csv}" \
					|| qa_die "harness bench failed ${corpus} ${piece}"
				;;
		esac
		qa_log "  ${backend}: done (${REPS} reps)"
	done
	cell_idx=$((cell_idx + 1))
done

rows="$(sed '/^$/d' "${csv}" | tail -n +2 | wc -l | tr -d ' ')"
expected=$(( ${#cells[@]} * 3 * REPS ))
assert_eq "${rows}" "${expected}" "CSV row count (${expected} = cells x backends x reps)"

qa_log "measurements: ${csv}"
qa_ok "benchmark matrix complete; run analyze_wp12.py for the §12.7 gate verdict"
qa_pass
