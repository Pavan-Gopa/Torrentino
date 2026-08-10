#!/usr/bin/env bash
#
# Torrentino — QA suite runner (Test Engineer).
#
# Role:     runs every cumulative safe test_wp01_*.sh … test_wp12_*.sh plus
#           the isolated WP-13 stability scripts and reports a per-script
#           result table. Live WP-02 scripts are blocked rather than touching
#           a pre-existing Human launchd session; Legacy is always waived.
#
# Usage:    bash Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh
#
set -uo pipefail

QA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Collect scripts in a stable (sorted) order: wp01 → wp02 → … → wp08.
scripts=()
while IFS= read -r s; do scripts+=("${s}"); done < <(
	{
		find "${QA_DIR}" -maxdepth 1 -name 'test_wp01_*.sh'
		find "${QA_DIR}" -maxdepth 1 -name 'test_wp02_*.sh'
		find "${QA_DIR}" -maxdepth 1 -name 'test_wp03_*.sh'
		find "${QA_DIR}" -maxdepth 1 -name 'test_wp04_*.sh'
		find "${QA_DIR}" -maxdepth 1 -name 'test_wp05_*.sh'
		find "${QA_DIR}" -maxdepth 1 -name 'test_wp06_*.sh'
		find "${QA_DIR}" -maxdepth 1 -name 'test_wp07_*.sh'
		find "${QA_DIR}" -maxdepth 1 -name 'test_wp08_*.sh'
		find "${QA_DIR}" -maxdepth 1 -name 'test_wp09_*.sh'
		find "${QA_DIR}" -maxdepth 1 -name 'test_wp10_*.sh'
		find "${QA_DIR}" -maxdepth 1 -name 'test_wp11_*.sh'
		find "${QA_DIR}" -maxdepth 1 -name 'test_wp12_*.sh'
		find "${QA_DIR}" -maxdepth 1 -name 'test_wp13_stability_*.sh'
	} | sort
)
[[ ${#scripts[@]} -gt 0 ]] || { echo "no cumulative QA scripts found" >&2; exit 2; }

echo "==> Torrentino QA suite: ${#scripts[@]} script(s)"
echo

declare -a names results
overall=0
wp02_environment_blocked=0
if launchctl print "gui/$(id -u)/com.torrentino.app.engine-agent" >/dev/null 2>&1 \
		|| pgrep -f TorrentinoEngineAgent >/dev/null 2>&1; then
	wp02_environment_blocked=1
	echo "ENVIRONMENTAL: pre-existing engine-agent session detected; live WP-02 scripts will be BLOCKED without touching it."
fi
for s in "${scripts[@]}"; do
	name="$(basename "${s}")"
	echo "=============================================================="
	echo ">>> ${name}"
	if [[ "${name}" == "test_wp03_legacy_untouched.sh" ]]; then
		echo "WAIVED: Legacy is forbidden to read during ADR-020 stabilization."
		names+=("${name}")
		results+=("WAIVED (0s)")
		echo
		continue
	fi
	if [[ "${name}" == test_wp02_* && ${wp02_environment_blocked} -eq 1 ]]; then
		echo "BLOCKED: pre-existing Human launchd job/process owns the frozen XPC identity."
		names+=("${name}")
		results+=("BLOCKED (0s)")
		overall=1
		echo
		continue
	fi
	echo "=============================================================="
	start=$(date +%s)
	if bash "${s}"; then
		res="PASS"
	else
		res="FAIL"
		overall=1
	fi
	dur=$(( $(date +%s) - start ))
	names+=("${name}")
	results+=("${res} (${dur}s)")
	echo
done

echo "=============================================================="
echo "QA SUITE SUMMARY"
echo "=============================================================="
printf '%-48s %s\n' "SCRIPT" "RESULT"
for i in "${!names[@]}"; do
	printf '%-48s %s\n' "${names[$i]}" "${results[$i]}"
done
echo

pass_n=$(printf '%s\n' "${results[@]}" | grep -c '^PASS' || true)
fail_n=$(printf '%s\n' "${results[@]}" | grep -c '^FAIL' || true)
blocked_n=$(printf '%s\n' "${results[@]}" | grep -c '^BLOCKED' || true)
waived_n=$(printf '%s\n' "${results[@]}" | grep -c '^WAIVED' || true)
wp01_n=0; wp02_n=0; wp03_n=0; wp04_n=0; wp05_n=0; wp06_n=0; wp07_n=0; wp08_n=0; wp09_n=0; wp10_n=0; wp11_n=0; wp12_n=0; wp13_n=0
for n in "${names[@]}"; do
	case "${n}" in
		test_wp01_*) wp01_n=$((wp01_n+1)) ;;
		test_wp02_*) wp02_n=$((wp02_n+1)) ;;
		test_wp03_*) wp03_n=$((wp03_n+1)) ;;
		test_wp04_*) wp04_n=$((wp04_n+1)) ;;
		test_wp05_*) wp05_n=$((wp05_n+1)) ;;
		test_wp06_*) wp06_n=$((wp06_n+1)) ;;
		test_wp07_*) wp07_n=$((wp07_n+1)) ;;
		test_wp08_*) wp08_n=$((wp08_n+1)) ;;
		test_wp09_*) wp09_n=$((wp09_n+1)) ;;
		test_wp10_*) wp10_n=$((wp10_n+1)) ;;
		test_wp11_*) wp11_n=$((wp11_n+1)) ;;
		test_wp12_*) wp12_n=$((wp12_n+1)) ;;
		test_wp13_*) wp13_n=$((wp13_n+1)) ;;
	esac
done
echo "total: ${#names[@]}  pass: ${pass_n}  fail: ${fail_n}  blocked: ${blocked_n}  waived: ${waived_n}  (wp01: ${wp01_n}  wp02: ${wp02_n}  wp03: ${wp03_n}  wp04: ${wp04_n}  wp05: ${wp05_n}  wp06: ${wp06_n}  wp07: ${wp07_n}  wp08: ${wp08_n}  wp09: ${wp09_n}  wp10: ${wp10_n}  wp11: ${wp11_n}  wp12: ${wp12_n}  wp13: ${wp13_n})"
if [[ ${overall} -eq 0 ]]; then
	echo "SUITE RESULT: GREEN"
else
	echo "SUITE RESULT: FAIL" >&2
fi
exit "${overall}"
