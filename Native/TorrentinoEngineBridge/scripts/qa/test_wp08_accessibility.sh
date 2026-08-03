#!/usr/bin/env bash
#
# QA WP-08 - VoiceOver labels, reduce motion, contrast, and inline errors.
#
# Merely declaring an accessibility environment value is not support. It must
# be read by behavior or styling, and controls hidden with labelsHidden must
# still have an accessibility label.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

APP_DIR="${NATIVE_DIR}/TorrentinoApp"
LIST="${NATIVE_DIR}/TorrentinoApp/Features/TorrentListView.swift"
INSPECTOR="${NATIVE_DIR}/TorrentinoApp/Features/InspectorView.swift"

[[ -d "${APP_DIR}" ]] || qa_die "TorrentinoApp source directory is missing"

python3 - "${APP_DIR}" "${LIST}" "${INSPECTOR}" <<'PY'
import re
import sys
from pathlib import Path

app_dir = Path(sys.argv[1])
list_source = Path(sys.argv[2]).read_text(encoding="utf-8")
inspector_source = Path(sys.argv[3]).read_text(encoding="utf-8")
all_source = "\n".join(p.read_text(encoding="utf-8") for p in app_dir.rglob("*.swift"))
issues = []

for name, source in (("TorrentListView", list_source), ("InspectorView", inspector_source)):
    if r"@Environment(\.accessibilityReduceMotion)" not in source:
        issues.append(f"{name} does not read accessibilityReduceMotion")
    elif len(re.findall(r'\breduceMotion\b', source)) < 2:
        issues.append(f"{name} declares reduceMotion but never uses it to change behavior")
    if r"@Environment(\.colorSchemeContrast)" not in source:
        issues.append(f"{name} does not read colorSchemeContrast")
    elif len(re.findall(r'\bcontrast\b', source)) < 2:
        issues.append(f"{name} declares contrast but never uses it to change styling/behavior")

if len(re.findall(r'\.accessibilityLabel\(', all_source)) < 4:
    issues.append("fewer than four explicit accessibility labels exist")

toggle_match = re.search(r'Toggle\("",.*?\.toggleStyle\(\.checkbox\)', list_source, re.S)
if toggle_match and ".accessibilityLabel(" not in toggle_match.group(0):
    issues.append("file-selection checkbox is labelsHidden without an accessibility label")

if re.search(r'\.alert\(', all_source):
    issues.append("routine app error path uses a modal .alert")
if "validationErrors" not in Path(sys.argv[1], "Features/Settings/SettingsView.swift").read_text(encoding="utf-8"):
    issues.append("Settings has no inline validation error state")

if issues:
    for issue in issues:
        print(f"FAIL: {issue}", file=sys.stderr)
    sys.exit(1)

print("OK: explicit labels, accessibility modes, and inline error behavior are present")
PY

qa_ok "accessibility/keyboard/contrast/motion source contract"
qa_pass
