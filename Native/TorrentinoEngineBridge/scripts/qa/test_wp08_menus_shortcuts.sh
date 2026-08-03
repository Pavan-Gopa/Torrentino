#!/usr/bin/env bash
#
# QA WP-08 - native menus and shortcut uniqueness.
#
# The shortcut map is parsed across all app Swift files so a duplicate hidden
# in a secondary view is still reported.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

APP_DIR="${NATIVE_DIR}/TorrentinoApp"
[[ -d "${APP_DIR}" ]] || qa_die "TorrentinoApp source directory is missing"

python3 - "${APP_DIR}" <<'PY'
import re
import sys
from collections import Counter
from pathlib import Path

root = Path(sys.argv[1])
source = "\n".join(p.read_text(encoding="utf-8") for p in sorted(root.rglob("*.swift")))
issues = []

for menu in ("file", "edit", "torrent", "view"):
    needle = f'CommandMenu(String(localized: "menu.{menu}")'
    if needle not in source:
        issues.append(f"{menu.capitalize()} menu is not declared")

patterns = {
    "Cmd+N": r'\.keyboardShortcut\(\s*"n"\s*,\s*modifiers:\s*\.command\s*\)',
    "Cmd+Shift+N": r'\.keyboardShortcut\(\s*"n"\s*,\s*modifiers:\s*\[\.command\s*,\s*\.shift\]\s*\)',
    "Cmd+.": r'\.keyboardShortcut\(\s*"\."\s*,\s*modifiers:\s*\.command\s*\)',
    "Cmd+/": r'\.keyboardShortcut\(\s*"/"\s*,\s*modifiers:\s*\.command\s*\)',
    "Cmd+Delete": r'\.keyboardShortcut\(\s*\.delete\s*,\s*modifiers:\s*\.command\s*\)',
    "Cmd+R": r'\.keyboardShortcut\(\s*"r"\s*,\s*modifiers:\s*\.command\s*\)',
    "Cmd+I": r'\.keyboardShortcut\(\s*"i"\s*,\s*modifiers:\s*\.command\s*\)',
    "Cmd+F": r'\.keyboardShortcut\(\s*"f"\s*,\s*modifiers:\s*\.command\s*\)',
}
for label, pattern in patterns.items():
    if not re.search(pattern, source):
        issues.append(f"{label} shortcut is missing")

shortcut_pattern = re.compile(
    r'\.keyboardShortcut\(\s*("[^"]+"|\.delete)\s*,\s*modifiers:\s*([^\)]+)\)'
)
keys = []
for match in shortcut_pattern.finditer(source):
    key = match.group(1)
    modifiers = re.sub(r"\s+", "", match.group(2))
    keys.append(f"{key}|{modifiers}")
duplicates = [key for key, count in Counter(keys).items() if count > 1]
if duplicates:
    issues.append("duplicate shortcuts: " + ", ".join(sorted(duplicates)))

if issues:
    for issue in issues:
        print(f"FAIL: {issue}", file=sys.stderr)
    sys.exit(1)

print("OK: File/Edit/Torrent/View menus and all required unique shortcuts are present")
PY

qa_ok "menus and shortcut source contract"
qa_pass
