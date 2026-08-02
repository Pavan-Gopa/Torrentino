#!/usr/bin/env bash
#
# Torrentino — WP-01 QA suite runner (Test Engineer).
#
# Role:     runs EVERY test_wp01_*.sh script (regression + new) and reports a
#           per-script pass/fail table. Exit 0 only if all scripts pass. This is
#           the single entry point for "run it all"; WP-02+ adds scripts here and
#           they are picked up automatically (monotonic coverage).
#
# Usage:    bash Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh
#
set -uo pipefail

QA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Collect scripts in a stable (sorted) order.
scripts=()
while IFS= read -r s; do scripts+=("${s}"); done < <(find "${QA_DIR}" -maxdepth 1 -name 'test_wp01_*.sh' | sort)
[[ ${#scripts[@]} -gt 0 ]] || { echo "no test_wp01_*.sh scripts found" >&2; exit 2; }

echo "==> WP-01 QA suite: ${#scripts[@]} script(s)"
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
echo "WP-01 QA SUITE SUMMARY"
echo "=============================================================="
printf '%-44s %s\n' "SCRIPT" "RESULT"
for i in "${!names[@]}"; do
	printf '%-44s %s\n' "${names[$i]}" "${results[$i]}"
done
echo

pass_n=$(printf '%s\n' "${results[@]}" | grep -c '^PASS' || true)
fail_n=$(printf '%s\n' "${results[@]}" | grep -c '^FAIL' || true)
echo "total: ${#names[@]}  pass: ${pass_n}  fail: ${fail_n}"
if [[ ${overall} -eq 0 ]]; then
	echo "SUITE RESULT: GREEN"
else
	echo "SUITE RESULT: FAIL" >&2
fi
exit "${overall}"
