#!/usr/bin/env bash
# WP-14 headless libtorrent reference baselines (isolated, loopback-free hash work).
# Writes primary 2.1.1 and fallback 2.0.14 hybrid/v2 Release measurements.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

PRIMARY="${BRIDGE_DIR}/.build/harness-2.1.1-release/torrentino-harness"
FALLBACK="${BRIDGE_DIR}/.build/harness-2.0.14-release/torrentino-harness"
[[ -x "${PRIMARY}" ]] || qa_die "2.1.1 Release harness missing: ${PRIMARY}"
[[ -x "${FALLBACK}" ]] || qa_die "2.0.14 Release harness missing: ${FALLBACK}"

REPS="${WP14_HEADLESS_REPS:-7}"
[[ "${REPS}" =~ ^[1-9][0-9]*$ ]] || qa_die "WP14_HEADLESS_REPS must be a positive integer"
ROOT="$(qa_mktemp)"
CORPUS="${ROOT}/corpus-256m"
mkdir -p "${CORPUS}"
"${PRIMARY}" gen-corpus --path "${CORPUS}/payload.bin" --size 268435456 --seed 14 >/dev/null 2>&1

MEAS_DIR="${REPO_ROOT}/Measurements/wp14"
mkdir -p "${MEAS_DIR}"
RUN_ID="${WP14_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
CSV="${MEAS_DIR}/headless-${RUN_ID}.csv"
ENVLOG="${MEAS_DIR}/environment-${RUN_ID}.txt"
ERRLOG="${MEAS_DIR}/headless-${RUN_ID}.stderr.log"

{
    echo "run_id=${RUN_ID}"
    echo "utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "macos=$(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    echo "arch=$(uname -m)"
    echo "kernel=$(uname -r)"
    echo "chip=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo n/a)"
    echo "logical_cpu=$(sysctl -n hw.ncpu)"
    echo "memory_gib=$(($(sysctl -n hw.memsize) / 1024 / 1024 / 1024))"
    echo "configuration=Release"
    echo "corpus_bytes=268435456"
    echo "piece_kib=1024"
    echo "formats=hybrid,v2"
    echo "reps=${REPS}"
    echo "primary=$("${PRIMARY}" version | tr '\n' ';')"
    echo "fallback=$("${FALLBACK}" version | tr '\n' ';')"
} > "${ENVLOG}"

printf '%s\n' "libtorrent_version,format,run,cell,backend,wall_s,cpu_s,peak_rss_mb,thermal_before,thermal_after,cpu_speed_limit,gpu_wall_s,fallbacks,staged_bytes,throughput_mib_s" > "${CSV}"
: > "${ERRLOG}"
rows=0
for pair in "2.1.1|${PRIMARY}" "2.0.14|${FALLBACK}"; do
    version="${pair%%|*}"
    harness="${pair#*|}"
    for format in hybrid v2; do
        qa_log "headless baseline libtorrent=${version} format=${format} reps=${REPS}"
        "${harness}" bench-hash --dir "${ROOT}" --name corpus-256m --piece 1024 --format "${format}" --reps 1 \
            >/dev/null 2>>"${ERRLOG}"
        raw="${ROOT}/raw-${version}-${format}.csv"
        "${harness}" bench-hash --dir "${ROOT}" --name corpus-256m --piece 1024 --format "${format}" --reps "${REPS}" \
            >"${raw}" 2>>"${ERRLOG}"
        while IFS= read -r line; do
            [[ -n "${line}" ]] || continue
            case "${line}" in
                run,cell,*|*" INFO "*) continue ;;
            esac
            printf '%s,%s,%s\n' "${version}" "${format}" "${line}" >> "${CSV}"
            rows=$((rows + 1))
        done < "${raw}"
    done
done

expected=$((REPS * 4))
assert_eq "${rows}" "${expected}" "headless CSV rows (2 pins x 2 formats x reps)"
assert_file "${CSV}" "headless baseline CSV"
assert_file "${ENVLOG}" "hardware and benchmark manifest"
qa_ok "WP-14 headless baselines: ${CSV}"
qa_pass
