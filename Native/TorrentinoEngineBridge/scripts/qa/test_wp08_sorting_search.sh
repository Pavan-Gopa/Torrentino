#!/usr/bin/env bash
#
# QA WP-08 - sortable table columns, Cmd+F search, and batch actions.
#
# Every visible table column must provide a value key path. A cell renderer
# alone is not sortable, which is why this check parses the TableColumn labels
# instead of only looking for the word "sorting" in comments.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

LIST="${NATIVE_DIR}/TorrentinoApp/Features/TorrentListView.swift"
MODEL="${NATIVE_DIR}/TorrentinoApp/Features/TorrentListViewModel.swift"
APP="${NATIVE_DIR}/TorrentinoApp/App/TorrentinoApp.swift"

[[ -f "${LIST}" ]] || qa_die "TorrentListView.swift is missing"
[[ -f "${MODEL}" ]] || qa_die "TorrentListViewModel.swift is missing"
[[ -f "${APP}" ]] || qa_die "TorrentinoApp.swift is missing"

python3 - "${LIST}" "${MODEL}" "${APP}" <<'PY'
import re
import sys
from pathlib import Path

list_source = Path(sys.argv[1]).read_text(encoding="utf-8")
model_source = Path(sys.argv[2]).read_text(encoding="utf-8")
app_source = Path(sys.argv[3]).read_text(encoding="utf-8")
issues = []

for column in ("name", "state", "progress", "down", "up", "size"):
    pattern = rf'TableColumn\(String\(localized: "torrents\.col\.{column}"\),\s*value:'
    if not re.search(pattern, list_source):
        issues.append(f"column torrents.col.{column} has no sortable value key path")

for needle, description in (
    ('Table(filteredTorrents, selection: $viewModel.selection, sortOrder: $sortOrder)',
     "table selection and sort bindings"),
    ('.searchable(text: $viewModel.searchText', "search field binding"),
    ('localizedCaseInsensitiveContains(query)', "case-insensitive search filter"),
    ('func pauseSelected()', "batch pause action"),
    ('func resumeSelected()', "batch resume action"),
    ('func removeSelected()', "batch remove action"),
):
    if needle not in (list_source + "\n" + model_source):
        issues.append(f"missing {description}")

if not re.search(r'\.keyboardShortcut\(\s*"f"\s*,\s*modifiers:\s*(?:\.command|\[\.command\])\s*\)', app_source):
    issues.append("Cmd+F has no explicit shortcut in the app command lane")

remove_match = re.search(r'func removeSelected\(\)\s*\{(?P<body>.*?)\n\s*\}\n\s*func revealSelected', model_source, re.S)
if not remove_match:
    issues.append("could not isolate removeSelected implementation")
elif not re.search(r'EngineCommandV1|sendCommand', remove_match.group("body")):
    issues.append("removeSelected mutates only the UI array and never submits an engine command")

if issues:
    for issue in issues:
        print(f"FAIL: {issue}", file=sys.stderr)
    sys.exit(1)

print("OK: all six table columns sortable; search, Cmd+F, and batch command paths present")
PY

qa_ok "sorting/search/multi-selection source contract"
qa_pass
