#!/usr/bin/env bash
#
# Torrentino — QA suite runner (Test Engineer).
#
# Role:     runs EVERY test_wp01_*.sh … test_wp05_*.sh script (monotonic
#           regression) and reports a per-script pass/fail table. Exit 0 only
#           if all scripts pass.
#
# Usage:    bash Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh
#
set -uo pipefail

QA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Collect scripts in a stable (sorted) order: wp01 → wp02 → … → wp05.
scripts=()
while IFS= read -r s; do scripts+=("${s}"); done < <(
	{
		find "${QA_DIR}" -maxdepth 1 -name 'test_wp01_*.sh'
		find "${QA_DIR}" -maxdepth 1 -name 'test_wp02_*.sh'
		find "${QA_DIR}" -maxdepth 1 -name 'test_wp03_*.sh'
		find "${QA_DIR}" -maxdepth 1 -name 'test_wp04_*.sh'
		find "${QA_DIR}" -maxdepth 1 -name 'test_wp05_*.sh'
	} | sort
)
[[ ${#scripts[@]} -gt 0 ]] || { echo "no test_wp0{1,2,3,4,5}_*.sh scripts found" >&2; exit 2; }

echo "==> Torrentino QA suite: ${#scripts[@]} script(s)"
echo

declare -a names results
overall=0
for s in "${scripts[@]}"; do
	name="$(basename "${s}")"
	echo "=============================================================="
	echo ">>> ${name}"
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
wp01_n=0; wp02_n=0; wp03_n=0; wp04_n=0; wp05_n=0
for n in "${names[@]}"; do
	case "${n}" in
		test_wp01_*) wp01_n=$((wp01_n+1)) ;;
		test_wp02_*) wp02_n=$((wp02_n+1)) ;;
		test_wp03_*) wp03_n=$((wp03_n+1)) ;;
		test_wp04_*) wp04_n=$((wp04_n+1)) ;;
		test_wp05_*) wp05_n=$((wp05_n+1)) ;;
	esac
done
echo "total: ${#names[@]}  pass: ${pass_n}  fail: ${fail_n}  (wp01: ${wp01_n}  wp02: ${wp02_n}  wp03: ${wp03_n}  wp04: ${wp04_n}  wp05: ${wp05_n})"
if [[ ${overall} -eq 0 ]]; then
	echo "SUITE RESULT: GREEN"
else
	echo "SUITE RESULT: FAIL" >&2
fi
exit "${overall}"
